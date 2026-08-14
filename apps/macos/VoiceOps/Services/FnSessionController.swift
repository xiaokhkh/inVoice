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

    private let audio = AudioCaptureService()
    private let asr = ASRClient()
    private let fastASR = FastASRClient()
    private let injector = FocusInjector()
    private let selectionCapture = SelectionCaptureService.shared
    private let llmRouter = LLMRouter()
    private let fastChunkDuration: TimeInterval
    private let fastChunkFrames: Int
    private let fastChunkBytes: Int
    private let minFramesForASR: AVAudioFramePosition
    private let fastSampleRate: Int = 16_000

    private var sessionMachine = FnSessionStateMachine(cooldownDuration: 0.2)
    private var lastFrameCount: AVAudioFramePosition = 0
    private var fastSessionID: String?
    private var fastSessionToken: UUID?
    private var fastTask: Task<Void, Never>?
    private var selectedTextSnapshot: String?
    private var didRecordVoiceOps = false
    private var fastQueue: [Data] = []
    private var fastProcessing = false
    private var fastAccumulated = Data()
    private var lastPartialTimestamp: CFAbsoluteTime?
    private var lastPreviewText: String = ""

    var onIndicatorChange: ((IndicatorState) -> Void)?
    var onPreviewText: ((String) -> Void)?

    init(fastChunkDuration: TimeInterval = 0.1, minDuration: TimeInterval = 0.25) {
        self.fastChunkDuration = fastChunkDuration
        let frames = Int(Double(fastSampleRate) * fastChunkDuration)
        self.fastChunkFrames = max(frames, 320)
        self.fastChunkBytes = self.fastChunkFrames * MemoryLayout<Float>.size
        self.minFramesForASR = AVAudioFramePosition(Double(fastSampleRate) * minDuration)
    }

    @discardableResult
    func startSession() async -> Bool {
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

        let sessionID = context.id
        trace(
            "[fn_session] id=\(shortID(sessionID)) transition=idle->starting "
                + "target_pid=\(context.targetPID ?? -1) "
                + "target_app=\(context.targetBundleID ?? "unknown")"
        )
        resetPerSessionData()

        let granted = await Permissions.requestMicrophoneIfNeeded()
        guard sessionMachine.isCurrent(sessionID, phase: .starting) else {
            trace("[fn_session] id=\(shortID(sessionID)) startup_stale stage=permission")
            return false
        }
        guard granted else {
            trace("[fn_session] id=\(shortID(sessionID)) mic_denied")
            finishSession(sessionID: sessionID)
            return false
        }

        // AX is used only to capture optional selection context for history and
        // LLM routing. It is never used as the final text delivery path.
        let selection = await selectionCapture.captureSelection(mode: .axOnly)
        guard sessionMachine.isCurrent(sessionID, phase: .starting) else {
            trace("[fn_session] id=\(shortID(sessionID)) startup_stale stage=selection")
            return false
        }
        selectedTextSnapshot = selection.text
        Task { [weak self] in
            await self?.llmRouter.warmUp()
        }

        do {
            try audio.start(
                streaming: true,
                chunkDuration: 1.0,
                onChunk: { [weak self] data, frames in
                    self?.handleFastChunk(data: data, frames: frames)
                },
                storeBuffers: true,
                writeToFile: false
            )
        } catch {
            trace("[fn_session] id=\(shortID(sessionID)) audio_start_failed error=\(error)")
            finishSession(sessionID: sessionID)
            return false
        }

        guard let shouldStopImmediately = sessionMachine.recordingDidStart(
            sessionID: sessionID
        ) else {
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
            fastSessionToken = UUID()
            Task { [weak self] in
                await self?.startFastSession(for: sessionID)
            }
        }
        return true
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

    private func stopListening(sessionID: UUID) {
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }
        onIndicatorChange?(.processing)
        stopFastSession()

        do {
            let (wavData, totalFrames) = try audio.stopAndGetWavData()
            let frameCount = max(lastFrameCount, totalFrames)
            guard frameCount >= minFramesForASR else {
                trace(
                    "[asr_request_end] id=\(shortID(sessionID)) "
                        + "empty frames=\(frameCount)"
                )
                finishSession(sessionID: sessionID)
                return
            }
            Task { @MainActor [weak self] in
                await self?.runFinalASR(wavData: wavData, sessionID: sessionID)
            }
        } catch {
            trace(
                "[fn_session] id=\(shortID(sessionID)) "
                    + "audio_stop_failed error=\(error)"
            )
            finishSession(sessionID: sessionID)
        }
    }

    private func runFinalASR(wavData: Data, sessionID: UUID) async {
        guard sessionMachine.isCurrent(sessionID, phase: .processing) else { return }
        let totalStart = CFAbsoluteTimeGetCurrent()
        defer { finishSession(sessionID: sessionID) }

        trace("[asr_request_start] id=\(shortID(sessionID))")
        do {
            let asrStart = CFAbsoluteTimeGetCurrent()
            let text = try await asr.transcribe(wavData: wavData)
            let asrMs = Int((CFAbsoluteTimeGetCurrent() - asrStart) * 1000)
            guard sessionMachine.isCurrent(sessionID, phase: .processing) else {
                trace("[asr_request_end] id=\(shortID(sessionID)) stale=true")
                return
            }
            trace("[asr_request_end] id=\(shortID(sessionID)) len=\(text.count)")
            guard !text.isEmpty else { return }

            let llmStart = CFAbsoluteTimeGetCurrent()
            let routed = await llmRouter.route(text: text)
            let llmMs = Int((CFAbsoluteTimeGetCurrent() - llmStart) * 1000)
            guard sessionMachine.isCurrent(sessionID, phase: .processing) else {
                trace("[llm_result] id=\(shortID(sessionID)) stale=true")
                return
            }

            let finalText = routed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty,
                  let context = sessionMachine.context(for: sessionID),
                  sessionMachine.claimInsertion(sessionID: sessionID) else {
                trace("[inject_claim] id=\(shortID(sessionID)) claimed=false")
                return
            }
            trace("[fn_session] id=\(shortID(sessionID)) transition=processing->inserting")

            let injectStart = CFAbsoluteTimeGetCurrent()
            let result = await injector.deliver(
                finalText,
                targetPID: context.targetPID,
                restoreClipboard: true,
                sessionGuard: { [weak self] in
                    self?.sessionMachine.isCurrent(sessionID, phase: .inserting) == true
                }
            )
            let injectMs = Int((CFAbsoluteTimeGetCurrent() - injectStart) * 1000)
            trace(
                "[inject_result] id=\(shortID(sessionID)) "
                    + "status=\(result.status.rawValue)"
            )

            if !didRecordVoiceOps {
                let llmUsed = routed.offlineUsed ? "offline" : "none"
                ClipboardStore.shared.recordVoiceOpsText(
                    sessionID: sessionID,
                    text: finalText,
                    selectedText: selectedTextSnapshot,
                    voiceIntent: text,
                    llmUsed: llmUsed,
                    appBundleID: context.targetBundleID
                )
                didRecordVoiceOps = true
            }

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
            trace(
                "[perf] id=\(shortID(sessionID)) asr=\(asrMs)ms "
                    + "llm=\(llmMs)ms inject=\(injectMs)ms total=\(totalMs)ms"
            )
        } catch {
            trace("[asr_request_end] id=\(shortID(sessionID)) error=\(error)")
        }
    }

    private func finishSession(sessionID: UUID) {
        guard sessionMachine.complete(
            sessionID: sessionID,
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            return
        }

        audio.resetStreamingState()
        stopFastSession()
        resetPerSessionData()
        onIndicatorChange?(.idle)
        trace("[fn_session] id=\(shortID(sessionID)) transition=finished->idle")
    }

    private func resetPerSessionData() {
        lastFrameCount = 0
        fastSessionID = nil
        fastSessionToken = nil
        fastTask?.cancel()
        fastTask = nil
        selectedTextSnapshot = nil
        didRecordVoiceOps = false
        fastQueue = []
        fastProcessing = false
        fastAccumulated = Data()
        lastPartialTimestamp = nil
        lastPreviewText = ""
    }

    private func startFastSession(for voiceSessionID: UUID) async {
        let token = fastSessionToken
        do {
            let sessionID = try await fastASR.startSession()
            guard sessionMachine.isCurrent(voiceSessionID, phase: .listening),
                  token != nil,
                  token == fastSessionToken else {
                _ = try? await fastASR.endSession(sessionID: sessionID)
                return
            }
            fastSessionID = sessionID
            drainFastQueueIfNeeded(for: voiceSessionID)
        } catch {
            trace("[fast_asr_start_failed] id=\(shortID(voiceSessionID)) error=\(error)")
        }
    }

    private func stopFastSession() {
        if let sessionID = fastSessionID {
            Task { [weak self] in
                _ = try? await self?.fastASR.endSession(sessionID: sessionID)
            }
        }
        fastSessionID = nil
        fastSessionToken = nil
        fastTask?.cancel()
        fastTask = nil
        fastQueue.removeAll()
        fastProcessing = false
        fastAccumulated = Data()
        lastPartialTimestamp = nil
    }

    private func handleFastChunk(data: Data, frames: AVAudioFrameCount) {
        guard let sessionID = sessionMachine.currentContext?.id,
              sessionMachine.isCurrent(sessionID, phase: .listening),
              fastSessionToken != nil,
              !data.isEmpty else {
            return
        }

        lastFrameCount += AVAudioFramePosition(frames)
        fastAccumulated.append(data)
        while fastAccumulated.count >= fastChunkBytes {
            let chunk = Data(fastAccumulated.prefix(fastChunkBytes))
            fastAccumulated.removeSubrange(0..<fastChunkBytes)
            fastQueue.append(chunk)
        }
        drainFastQueueIfNeeded(for: sessionID)
    }

    private func drainFastQueueIfNeeded(for voiceSessionID: UUID) {
        guard !fastProcessing else { return }
        fastProcessing = true
        fastTask = Task { @MainActor [weak self] in
            await self?.processFastQueue(for: voiceSessionID)
        }
    }

    private func processFastQueue(for voiceSessionID: UUID) async {
        let token = fastSessionToken
        while sessionMachine.isCurrent(voiceSessionID, phase: .listening) {
            guard token != nil, token == fastSessionToken else { break }
            guard let sessionID = fastSessionID else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            guard !fastQueue.isEmpty else { break }

            let chunk = fastQueue.removeFirst()
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let (text, latency) = try await fastASR.pushSamples(
                    sessionID: sessionID,
                    samples: chunk,
                    sampleRate: fastSampleRate
                )
                guard sessionMachine.isCurrent(voiceSessionID, phase: .listening),
                      token == fastSessionToken else {
                    break
                }

                let now = CFAbsoluteTimeGetCurrent()
                if let last = lastPartialTimestamp {
                    trace(
                        "[update_rate] id=\(shortID(voiceSessionID)) "
                            + "ms=\(Int((now - last) * 1000))"
                    )
                }
                lastPartialTimestamp = now

                // Fast ASR owns preview only. It has no reference to an
                // injector, so partial results cannot mutate the target app.
                if text != lastPreviewText {
                    lastPreviewText = text
                    onPreviewText?(text)
                }

                let elapsedMs = Int((now - started) * 1000)
                trace(
                    "[fast_asr_latency] id=\(shortID(voiceSessionID)) "
                        + "server=\(latency.map(String.init) ?? "unknown")ms "
                        + "push=\(elapsedMs)ms"
                )
            } catch {
                trace("[fast_asr_error] id=\(shortID(voiceSessionID)) error=\(error)")
            }
        }
        fastProcessing = false
        fastTask = nil
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}
