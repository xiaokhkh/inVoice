import AppKit
import AVFoundation
import Foundation

@MainActor
final class FnSessionController {
    enum IndicatorState {
        case idle
        case recording
        case processing
    }

    private let audio: AudioCaptureService
    private let asr: any FinalASRTranscribing
    private let streamingASR: any StreamingASRServing
    private let injector = FocusInjector()
    private let selectionCapture = SelectionCaptureService.shared
    private let llmRouter: any DictationLLMRouting
    private let metricsStore: any SessionMetricsRecording
    private let minFramesForASR: AVAudioFramePosition
    private let fastSampleRate = 16_000

    private var sessionMachine = FnSessionStateMachine(cooldownDuration: 0.2)
    private var selectedTextSnapshot: String?
    private var didRecordVoiceOps = false
    private var asrMode: DictationASRMode = .accurate
    private var postProcessMode: DictationPostProcessMode = .translateAndPolish
    private var streamingPolicy = StreamingASRPolicy()

    private var streamToken: UUID?
    private var streamStartTask: Task<Void, Never>?
    private var streamSendTask: Task<Void, Never>?
    private var streamFinishTask: Task<StreamingFinalResult, Never>?
    private var streamReady = false
    private var streamInvalidReason: String?
    private var streamQueue = BoundedStreamingAudioQueue(capacity: 30)
    private var streamSending = false
    private var pcmChunker: Float32PCMChunker
    private var lastSentSequence: UInt64?
    private var sentFrames: Int64 = 0
    private var lastPartialTimestamp: CFAbsoluteTime?
    private var lastPreviewText = ""

    private var sessionStartedAt: CFAbsoluteTime = 0
    private var stopRequestedAt: CFAbsoluteTime?
    private var metric: SessionMetricV1?

    var onIndicatorChange: ((IndicatorState) -> Void)?
    var onPreviewText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?
    var onDeliveryResult: ((FocusInjector.DeliveryStatus) -> Void)?
    var onFailure: ((String) -> Void)?

    init(
        fastChunkDuration: TimeInterval = 0.1,
        minDuration: TimeInterval = 0.25,
        audio: AudioCaptureService = AudioCaptureService(),
        asr: any FinalASRTranscribing = ASRClient(),
        streamingASR: any StreamingASRServing = StreamingASRClient(),
        llmRouter: any DictationLLMRouting = LLMRouter(),
        metricsStore: any SessionMetricsRecording = SessionMetricsStore.shared
    ) {
        let frames = Int(Double(fastSampleRate) * fastChunkDuration)
        self.pcmChunker = Float32PCMChunker(targetFrames: max(frames, 320))
        self.minFramesForASR = AVAudioFramePosition(Double(fastSampleRate) * minDuration)
        self.audio = audio
        self.asr = asr
        self.streamingASR = streamingASR
        self.llmRouter = llmRouter
        self.metricsStore = metricsStore
    }

    @discardableResult
    func startSession(provider: VoiceInputProvider = .usbAudio) async -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let now = ProcessInfo.processInfo.systemUptime
        guard let context = sessionMachine.begin(
            targetPID: frontmost?.processIdentifier,
            targetBundleID: frontmost?.bundleIdentifier,
            now: now
        ) else {
            trace(
                "[fn_session] start_ignored phase=\(sessionMachine.phase.rawValue) "
                    + "cooldown_until=\(sessionMachine.cooldownUntil)"
            )
            return false
        }

        resetPerSessionData()
        let sessionID = context.id
        asrMode = DictationPreferences.asrMode()
        postProcessMode = DictationPreferences.postProcessMode()
        streamingPolicy = StreamingASRPolicy(
            approvedAdaptiveClasses: DictationPreferences.approvedAdaptiveClasses()
        )
        sessionStartedAt = CFAbsoluteTimeGetCurrent()
        metric = SessionMetricV1(
            sessionID: sessionID,
            asrMode: asrMode,
            postProcessMode: postProcessMode
        )
        streamToken = UUID()

        trace(
            "[fn_session] id=\(shortID(sessionID)) transition=idle->starting "
                + "target_pid=\(context.targetPID ?? -1) "
                + "target_app=\(context.targetBundleID ?? "unknown") "
                + "provider=\(provider.rawValue) "
                + "asr_mode=\(asrMode.rawValue) post=\(postProcessMode.rawValue)"
        )

        let granted = provider.requiresMicrophonePermission
            ? await Permissions.requestMicrophoneIfNeeded()
            : true
        guard sessionMachine.isCurrent(sessionID, phase: .starting) else {
            trace("[fn_session] id=\(shortID(sessionID)) startup_stale stage=permission")
            return false
        }
        guard granted else {
            trace("[fn_session] id=\(shortID(sessionID)) mic_denied")
            finishSession(sessionID: sessionID, outcome: "microphone_denied")
            onFailure?("请先允许麦克风访问，再开始听写")
            return false
        }

        let selection = await selectionCapture.captureSelection(mode: .axOnly)
        guard sessionMachine.isCurrent(sessionID, phase: .starting) else {
            trace("[fn_session] id=\(shortID(sessionID)) startup_stale stage=selection")
            return false
        }
        selectedTextSnapshot = selection.text
        Task { [weak self] in
            guard let self else { return }
            let warmupMs = await self.llmRouter.warmUp(mode: self.postProcessMode)
            guard self.sessionMachine.isCurrent(sessionID) else { return }
            self.updateMetric { $0.llmWarmupMs = warmupMs }
        }

        do {
            try audio.start(
                provider: provider,
                streaming: true,
                chunkDuration: 1.0,
                onChunk: { [weak self] data, frames in
                    self?.handleFastChunk(data: data, frames: frames)
                },
                writeToFile: true
            )
        } catch {
            trace("[fn_session] id=\(shortID(sessionID)) audio_start_failed error=\(error)")
            finishSession(sessionID: sessionID, outcome: "audio_start_failed")
            onFailure?("麦克风未能启动，请检查输入设备")
            return false
        }

        guard let shouldStopImmediately = sessionMachine.recordingDidStart(sessionID: sessionID) else {
            audio.cancel()
            trace("[fn_session] id=\(shortID(sessionID)) audio_started_for_stale_session")
            return false
        }

        if shouldStopImmediately {
            trace(
                "[fn_session] id=\(shortID(sessionID)) "
                    + "transition=starting->processing pending_stop=true"
            )
            stopListening(sessionID: sessionID)
        } else {
            trace("[fn_session] id=\(shortID(sessionID)) transition=starting->listening")
            onIndicatorChange?(.recording)
            startStreamingSession(for: sessionID)
        }
        return true
    }

    func appendWirelessAudio(_ packet: WirelessVoiceAudioPacket) {
        guard sessionMachine.phase == .listening else { return }
        audio.appendWirelessAudio(packet)
    }

    func endSession() {
        switch sessionMachine.requestStop() {
        case .ignored:
            trace("[fn_session] stop_ignored phase=\(sessionMachine.phase.rawValue)")
        case .deferred(let sessionID):
            trace("[fn_session] id=\(shortID(sessionID)) stop_deferred phase=starting")
        case .stopListening(let sessionID):
            trace("[fn_session] id=\(shortID(sessionID)) transition=listening->processing")
            stopListening(sessionID: sessionID)
        }
    }

    private func startStreamingSession(for voiceSessionID: UUID) {
        let token = streamToken
        streamStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.streamingASR.start(sessionID: voiceSessionID) { [weak self] text, latency, receivedFrames in
                    Task { @MainActor [weak self] in
                        self?.handlePartial(
                            text: text,
                            latencyMs: latency,
                            receivedFrames: receivedFrames,
                            sessionID: voiceSessionID
                        )
                    }
                }
                guard self.sessionMachine.isCurrent(voiceSessionID),
                      token != nil,
                      token == self.streamToken else {
                    return
                }
                self.streamReady = true
                self.drainStreamQueueIfNeeded(for: voiceSessionID)
            } catch {
                guard self.sessionMachine.isCurrent(voiceSessionID),
                      token != nil,
                      token == self.streamToken else { return }
                self.markStreamInvalid("stream_start_failed")
                self.trace("[stream_start_failed] id=\(self.shortID(voiceSessionID)) error=\(error)")
            }
        }
    }

    private func stopListening(sessionID: UUID) {
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }
        onIndicatorChange?(.processing)
        stopRequestedAt = CFAbsoluteTimeGetCurrent()
        updateMetric { metric in
            metric.stopAtMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartedAt) * 1_000)
        }

        do {
            let drainStarted = CFAbsoluteTimeGetCurrent()
            let capture = try audio.stopAndDrain()
            updateMetric { metric in
                metric.audioFrames = Int64(capture.totalFrames)
                metric.audioDurationMs = Int(Double(capture.totalFrames) / Double(fastSampleRate) * 1_000)
                metric.audioDrainMs = Int((CFAbsoluteTimeGetCurrent() - drainStarted) * 1_000)
            }
            guard capture.totalFrames >= minFramesForASR else {
                try? FileManager.default.removeItem(at: capture.wavURL)
                trace("[asr_request_end] id=\(shortID(sessionID)) empty frames=\(capture.totalFrames)")
                finishSession(sessionID: sessionID, outcome: "audio_too_short")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                await Task.yield()
                await self.processStoppedCapture(capture, sessionID: sessionID)
            }
        } catch {
            trace("[fn_session] id=\(shortID(sessionID)) audio_stop_failed error=\(error)")
            finishSession(sessionID: sessionID, outcome: "audio_stop_failed")
            onFailure?("录音未能完成，请重新按住说话")
        }
    }

    private func processStoppedCapture(
        _ capture: AudioCaptureService.CaptureResult,
        sessionID: UUID
    ) async {
        defer { try? FileManager.default.removeItem(at: capture.wavURL) }
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }

        flushTailChunk()
        let streamTask = Task { @MainActor [weak self] in
            guard let self else {
                return StreamingFinalResult(
                    sessionID: sessionID,
                    text: "",
                    receivedFrames: 0,
                    expectedFrames: Int64(capture.totalFrames),
                    lastSequence: nil,
                    clean: false,
                    truncated: true,
                    reason: "controller_released",
                    stableRevisionCount: 0,
                    stableDurationMs: 0,
                    modelID: nil,
                    modelHash: nil,
                    protocolVersion: 1
                )
            }
            return await self.finishStream(
                sessionID: sessionID,
                totalFrames: Int64(capture.totalFrames)
            )
        }
        streamFinishTask = streamTask

        switch asrMode {
        case .accurate:
            let transcriptionResult: Result<ASRClient.Transcription, Error>
            do {
                transcriptionResult = .success(try await asr.transcribeDetailed(wavURL: capture.wavURL))
            } catch {
                transcriptionResult = .failure(error)
            }
            switch transcriptionResult {
            case .success(let transcription):
                await runFinalPipeline(
                    sourceText: transcription.text,
                    voiceIntent: transcription.text,
                    asrQueueMs: transcription.queueMs,
                    asrInferMs: transcription.inferMs,
                    asrTotalMs: transcription.totalMs,
                    asrModelID: transcription.modelID,
                    asrModelHash: transcription.modelHash,
                    asrSource: "glm",
                    sessionID: sessionID
                )
            case .failure(let error):
                trace("[asr_request_end] id=\(shortID(sessionID)) error=\(error)")
                finishSession(sessionID: sessionID, outcome: "final_asr_failed")
                onFailure?("GLM-ASR is unavailable. Check Dictation settings and sidecar logs.")
            }
        case .fast, .adaptive:
            let streamResult = await streamTask.value
            switch streamingPolicy.decide(mode: asrMode, result: streamResult) {
            case .useStreaming(let text):
                await runFinalPipeline(
                    sourceText: text,
                    voiceIntent: text,
                    asrQueueMs: nil,
                    asrInferMs: nil,
                    asrTotalMs: nil,
                    asrModelID: streamResult.modelID,
                    asrModelHash: streamResult.modelHash,
                    asrSource: "stream",
                    sessionID: sessionID
                )
            case .useFinalASR(let reason):
                updateMetric { $0.fallbackReason = reason }
                do {
                    let transcription = try await asr.transcribeDetailed(wavURL: capture.wavURL)
                    await runFinalPipeline(
                        sourceText: transcription.text,
                        voiceIntent: transcription.text,
                        asrQueueMs: transcription.queueMs,
                        asrInferMs: transcription.inferMs,
                        asrTotalMs: transcription.totalMs,
                        asrModelID: transcription.modelID,
                        asrModelHash: transcription.modelHash,
                        asrSource: "glm_fallback",
                        sessionID: sessionID
                    )
                } catch {
                    trace("[asr_request_end] id=\(shortID(sessionID)) error=\(error)")
                    finishSession(sessionID: sessionID, outcome: "fallback_asr_failed")
                    onFailure?("Streaming fallback could not reach GLM-ASR. Your audio was kept until processing ended.")
                }
            }
        }
    }

    private func finishStream(sessionID: UUID, totalFrames: Int64) async -> StreamingFinalResult {
        guard sessionMachine.isCurrent(sessionID) else {
            return failedStreamResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                reason: "stale_session"
            )
        }
        let startDeadline = CFAbsoluteTimeGetCurrent() + 0.6
        while !streamReady,
              streamInvalidReason == nil,
              sessionMachine.isCurrent(sessionID),
              !Task.isCancelled,
              CFAbsoluteTimeGetCurrent() < startDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard sessionMachine.isCurrent(sessionID), !Task.isCancelled else {
            return failedStreamResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                reason: "stale_session"
            )
        }
        drainStreamQueueIfNeeded(for: sessionID)
        let drainDeadline = CFAbsoluteTimeGetCurrent() + 0.6
        while (streamSending || pendingStreamCount > 0),
              streamInvalidReason == nil,
              sessionMachine.isCurrent(sessionID),
              !Task.isCancelled,
              CFAbsoluteTimeGetCurrent() < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard sessionMachine.isCurrent(sessionID), !Task.isCancelled else {
            return failedStreamResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                reason: "stale_session"
            )
        }
        if pendingStreamCount > 0 || streamSending {
            markStreamInvalid("queue_drain_timeout")
        }
        if let streamInvalidReason {
            await streamingASR.abort()
            return measuredStreamResult(failedStreamResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                reason: streamInvalidReason
            ))
        }
        guard streamReady else {
            return measuredStreamResult(failedStreamResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                reason: "stream_not_ready"
            ))
        }

        let result = await streamingASR.finish(
            sessionID: sessionID,
            lastSequence: lastSentSequence,
            totalFrames: totalFrames,
            timeoutMs: 800
        )
        guard sessionMachine.isCurrent(sessionID), !Task.isCancelled else { return result }
        return measuredStreamResult(result)
    }

    private func runFinalPipeline(
        sourceText: String,
        voiceIntent: String,
        asrQueueMs: Int?,
        asrInferMs: Int?,
        asrTotalMs: Int?,
        asrModelID: String?,
        asrModelHash: String?,
        asrSource: String,
        sessionID: UUID
    ) async {
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }
        let asrCompletedAt = CFAbsoluteTimeGetCurrent()
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMetric { metric in
            metric.finalASRQueueMs = asrQueueMs
            metric.finalASRInferMs = asrInferMs
            metric.finalASRTotalMs = asrTotalMs
            metric.finalASRSource = asrSource
            metric.finalASRModelID = asrModelID
            metric.finalASRModelHash = asrModelHash
            if asrSource == "stream" {
                metric.fallbackReason = nil
            }
        }
        trace("[asr_request_end] id=\(shortID(sessionID)) source=\(asrSource) len=\(text.count)")
        guard !text.isEmpty else {
            finishSession(sessionID: sessionID, outcome: "empty_transcript")
            onFailure?("没有听清，请按住说话再试一次")
            return
        }

        let llmStart = CFAbsoluteTimeGetCurrent()
        let routed = await llmRouter.route(text: text, mode: postProcessMode)
        let llmMs = Int((CFAbsoluteTimeGetCurrent() - llmStart) * 1_000)
        updateMetric { metric in
            metric.llmMs = llmMs
            metric.llmLoadMs = routed.loadMs
            metric.llmPromptEvalMs = routed.promptEvalMs
            metric.llmGenerateMs = routed.generateMs
            metric.llmFailureReason = routed.reason
        }
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }

        let finalText = routed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty,
              let context = sessionMachine.context(for: sessionID),
              sessionMachine.claimInsertion(sessionID: sessionID) else {
            trace("[inject_claim] id=\(shortID(sessionID)) claimed=false")
            finishSession(sessionID: sessionID, outcome: "insertion_not_claimed")
            return
        }
        trace("[fn_session] id=\(shortID(sessionID)) transition=processing->inserting")
        onFinalText?(finalText)

        let injectStart = CFAbsoluteTimeGetCurrent()
        let result = await injector.deliver(
            finalText,
            targetPID: context.targetPID,
            restoreClipboard: true,
            sessionGuard: { [weak self] in
                self?.sessionMachine.isCurrent(sessionID, phase: .inserting) == true
            }
        )
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - injectStart) * 1_000)
        updateMetric { metric in
            metric.injectMs = injectMs
            metric.deliveryStatus = result.status.rawValue
            metric.endToEndMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartedAt) * 1_000)
            metric.outcome = "delivered"
        }
        trace("[inject_result] id=\(shortID(sessionID)) status=\(result.status.rawValue)")
        onDeliveryResult?(result.status)

        if !didRecordVoiceOps {
            let llmUsed = routed.offlineUsed ? "offline" : "none"
            ClipboardStore.shared.recordVoiceOpsText(
                sessionID: sessionID,
                text: finalText,
                selectedText: selectedTextSnapshot,
                voiceIntent: voiceIntent,
                llmUsed: llmUsed,
                appBundleID: context.targetBundleID
            )
            didRecordVoiceOps = true
        }

        trace(
            "[perf] id=\(shortID(sessionID)) source=\(asrSource) "
                + "post_asr=\(Int((CFAbsoluteTimeGetCurrent() - asrCompletedAt) * 1_000))ms "
                + "llm=\(llmMs)ms inject=\(injectMs)ms"
        )
        finishSession(sessionID: sessionID, outcome: "delivered")
    }

    private func handleFastChunk(data: Data, frames: AVAudioFrameCount) {
        guard let sessionID = sessionMachine.currentContext?.id,
              sessionMachine.isCurrent(sessionID),
              streamToken != nil,
              !data.isEmpty else {
            return
        }

        guard let chunks = pcmChunker.append(data) else {
            markStreamInvalid("invalid_pcm_length")
            return
        }
        for chunk in chunks {
            enqueueStreamChunk(chunk)
        }
        drainStreamQueueIfNeeded(for: sessionID)
    }

    private func flushTailChunk() {
        guard let tail = pcmChunker.finishTail() else { return }
        enqueueStreamChunk(tail)
    }

    private func enqueueStreamChunk(_ data: Data) {
        guard streamInvalidReason == nil else { return }
        switch streamQueue.enqueue(data) {
        case .enqueued:
            updateMetric { metric in
                metric.maxQueueDepth = max(metric.maxQueueDepth, pendingStreamCount)
            }
        case .overflow:
            updateMetric { $0.droppedChunks += 1 }
            markStreamInvalid("queue_overflow")
        case .invalidPCM:
            markStreamInvalid("invalid_pcm_length")
        }
    }

    private var pendingStreamCount: Int {
        streamQueue.count
    }

    private func popStreamChunk() -> StreamingAudioChunk? {
        streamQueue.popFirst()
    }

    private func drainStreamQueueIfNeeded(for voiceSessionID: UUID) {
        guard !streamSending, streamInvalidReason == nil else { return }
        streamSending = true
        let token = streamToken
        streamSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.streamSending = false
                self.streamSendTask = nil
            }
            while self.sessionMachine.isCurrent(voiceSessionID),
                  token != nil,
                  token == self.streamToken,
                  self.streamInvalidReason == nil {
                guard self.streamReady else {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continue
                }
                guard let chunk = self.popStreamChunk() else { break }
                do {
                    try await self.streamingASR.send(
                        sessionID: voiceSessionID,
                        samples: chunk.data,
                        sequence: chunk.sequence
                    )
                    self.lastSentSequence = chunk.sequence
                    self.sentFrames += chunk.frames
                } catch {
                    self.markStreamInvalid("stream_send_failed")
                    self.trace("[stream_send_failed] id=\(self.shortID(voiceSessionID)) error=\(error)")
                    break
                }
            }
        }
    }

    private func handlePartial(
        text: String,
        latencyMs: Int?,
        receivedFrames: Int64,
        sessionID: UUID
    ) {
        guard sessionMachine.isCurrent(sessionID) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        updateMetric { metric in
            metric.partialCount += 1
            if metric.firstPartialMs == nil {
                metric.firstPartialMs = Int((now - sessionStartedAt) * 1_000)
            }
        }
        if let last = lastPartialTimestamp {
            trace("[update_rate] id=\(shortID(sessionID)) ms=\(Int((now - last) * 1_000))")
        }
        lastPartialTimestamp = now
        if text != lastPreviewText {
            lastPreviewText = text
            onPreviewText?(text)
        }
        trace(
            "[stream_partial] id=\(shortID(sessionID)) server=\(latencyMs ?? -1)ms "
                + "received_frames=\(receivedFrames)"
        )
    }

    private func markStreamInvalid(_ reason: String) {
        guard streamInvalidReason == nil else { return }
        streamInvalidReason = reason
        streamQueue.removeAll()
        updateMetric { $0.fallbackReason = reason }
    }

    private func recordStreamResult(_ result: StreamingFinalResult) {
        updateMetric { metric in
            metric.streamClean = result.clean && !result.truncated && result.hasCompleteFrameCount
            metric.streamProtocolVersion = result.protocolVersion
            metric.streamModelID = result.modelID
            metric.streamModelHash = result.modelHash
            if let stopRequestedAt {
                metric.stopToStreamFinalMs = Int(
                    (CFAbsoluteTimeGetCurrent() - stopRequestedAt) * 1_000
                )
            }
            if !result.clean || result.truncated || !result.hasCompleteFrameCount {
                metric.fallbackReason = result.reason ?? "stream_not_clean"
            }
        }
    }

    private func measuredStreamResult(_ result: StreamingFinalResult) -> StreamingFinalResult {
        recordStreamResult(result)
        return result
    }

    private func failedStreamResult(
        sessionID: UUID,
        totalFrames: Int64,
        reason: String
    ) -> StreamingFinalResult {
        StreamingFinalResult(
            sessionID: sessionID,
            text: "",
            receivedFrames: sentFrames,
            expectedFrames: totalFrames,
            lastSequence: lastSentSequence,
            clean: false,
            truncated: true,
            reason: reason,
            stableRevisionCount: 0,
            stableDurationMs: 0,
            modelID: nil,
            modelHash: nil,
            protocolVersion: StreamingASRPolicy.requiredProtocolVersion
        )
    }

    private func finishSession(sessionID: UUID, outcome: String) {
        guard sessionMachine.complete(
            sessionID: sessionID,
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            return
        }

        updateMetric { metric in
            metric.outcome = outcome
            if metric.endToEndMs == nil {
                metric.endToEndMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartedAt) * 1_000)
            }
        }
        if let metric {
            Task { await metricsStore.record(metric) }
        }

        audio.resetStreamingState()
        streamStartTask?.cancel()
        streamSendTask?.cancel()
        streamFinishTask?.cancel()
        Task { await streamingASR.abort() }
        resetPerSessionData()
        onIndicatorChange?(.idle)
        trace("[fn_session] id=\(shortID(sessionID)) transition=finished->idle outcome=\(outcome)")
    }

    private func resetPerSessionData() {
        selectedTextSnapshot = nil
        didRecordVoiceOps = false
        streamToken = nil
        streamStartTask?.cancel()
        streamStartTask = nil
        streamSendTask?.cancel()
        streamSendTask = nil
        streamFinishTask?.cancel()
        streamFinishTask = nil
        streamReady = false
        streamInvalidReason = nil
        streamQueue = BoundedStreamingAudioQueue(capacity: 30)
        streamSending = false
        pcmChunker.reset()
        lastSentSequence = nil
        sentFrames = 0
        lastPartialTimestamp = nil
        lastPreviewText = ""
        stopRequestedAt = nil
        metric = nil
    }

    private func updateMetric(_ update: (inout SessionMetricV1) -> Void) {
        guard var metric else { return }
        update(&metric)
        self.metric = metric
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}
