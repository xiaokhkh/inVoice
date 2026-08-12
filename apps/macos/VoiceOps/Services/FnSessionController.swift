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

    private enum State {
        case idle
        case streaming
        case ending
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

    private var state: State = .idle
    private var isFinalProcessing = false
    private var lastFrameCount: AVAudioFramePosition = 0
    private var fastSessionID: String?
    private var fastSessionToken: UUID?
    private var fastTask: Task<Void, Never>?
    private var focusPID: pid_t?
    private var focusBundleID: String?
    private var currentSessionID: UUID?
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

    func startSession() async {
        guard state == .idle else { return }
        print("[fn_down]")

        let granted = await Permissions.requestMicrophoneIfNeeded()
        guard granted else {
            print("[fn_session] mic_denied")
            onIndicatorChange?(.idle)
            return
        }
        currentSessionID = UUID()
        let selection = await selectionCapture.captureSelection()
        selectedTextSnapshot = selection.text
        Task { [weak self] in
            await self?.llmRouter.warmUp()
        }

        lastFrameCount = 0
        fastSessionID = nil
        fastSessionToken = nil
        fastTask?.cancel()
        fastTask = nil
        let frontmost = NSWorkspace.shared.frontmostApplication
        focusPID = frontmost?.processIdentifier
        focusBundleID = frontmost?.bundleIdentifier
        didRecordVoiceOps = false
        fastQueue = []
        fastProcessing = false
        fastAccumulated = Data()
        lastPartialTimestamp = nil
        lastPreviewText = ""

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
            state = .streaming
            onIndicatorChange?(.recording)
            fastSessionToken = UUID()
            Task { [weak self] in
                await self?.startFastSession()
            }
        } catch {
            state = .idle
            print("[fn_session] audio_start_failed \(error)")
            onIndicatorChange?(.idle)
        }
    }

    func endSession() {
        guard state == .streaming else { return }
        print("[fn_up]")
        state = .ending
        onIndicatorChange?(.processing)
        stopFastSession()

        do {
            let (wavData, totalFrames) = try audio.stopAndGetWavData()
            let frameCount = max(lastFrameCount, totalFrames)
            if frameCount < minFramesForASR {
                print("[asr_request_end] empty")
                finishSession()
                return
            }
            Task { @MainActor [weak self] in
                await self?.runFinalASR(wavData: wavData)
            }
        } catch {
            print("[fn_session] audio_stop_failed \(error)")
            finishSession()
            return
        }
    }

    private func runFinalASR(wavData: Data) async {
        guard !isFinalProcessing else { return }
        isFinalProcessing = true
        let totalStart = CFAbsoluteTimeGetCurrent()
        let sessionID = currentSessionID
        defer {
            isFinalProcessing = false
            finishSession()
        }

        print("[asr_request_start]")
        do {
            let asrStart = CFAbsoluteTimeGetCurrent()
            let text = try await asr.transcribe(wavData: wavData)
            let asrMs = Int((CFAbsoluteTimeGetCurrent() - asrStart) * 1000)
            print("[asr_request_end] len=\(text.count)")

            guard !text.isEmpty else { return }
            let llmStart = CFAbsoluteTimeGetCurrent()
            let routed = await llmRouter.route(text: text)
            let llmMs = Int((CFAbsoluteTimeGetCurrent() - llmStart) * 1000)
            let finalText = routed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else { return }
            let injectStart = CFAbsoluteTimeGetCurrent()
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let didInject: Bool
            if let focusPID, focusPID == currentPID {
                didInject = injector.inject(finalText, restoreClipboard: false)
            } else {
                didInject = false
                print("[inject_skip] focus_mismatch expected=\(focusPID ?? -1) current=\(currentPID ?? -1)")
            }
            let injectMs = Int((CFAbsoluteTimeGetCurrent() - injectStart) * 1000)
            print("[inject_called] ok=\(didInject)")
            let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
            print("[perf] asr=\(asrMs)ms llm=\(llmMs)ms inject=\(injectMs)ms total=\(totalMs)ms")
            if !didInject, let focusPID, currentPID == focusPID {
                let fallback = injector.inject(text, restoreClipboard: false)
                print("[inject_fallback] ok=\(fallback)")
            }
            if let sessionID, !didRecordVoiceOps {
                let llmUsed = routed.offlineUsed ? "offline" : "none"
                ClipboardStore.shared.recordVoiceOpsText(
                    sessionID: sessionID,
                    text: finalText,
                    selectedText: selectedTextSnapshot,
                    voiceIntent: text,
                    llmUsed: llmUsed,
                    appBundleID: focusBundleID
                )
                didRecordVoiceOps = true
            }
        } catch {
            print("[asr_request_end] error=\(error)")
        }
    }

    private func finishSession() {
        audio.resetStreamingState()
        lastFrameCount = 0
        fastSessionID = nil
        fastSessionToken = nil
        fastTask?.cancel()
        fastTask = nil
        focusPID = nil
        focusBundleID = nil
        currentSessionID = nil
        selectedTextSnapshot = nil
        didRecordVoiceOps = false
        fastQueue = []
        fastProcessing = false
        fastAccumulated = Data()
        lastPartialTimestamp = nil
        lastPreviewText = ""
        state = .idle
        onIndicatorChange?(.idle)
        print("[fn_session] ended")
    }

    private func startFastSession() async {
        do {
            let sessionID = try await fastASR.startSession()
            fastSessionID = sessionID
            drainFastQueueIfNeeded()
        } catch {
            print("[fast_asr_start_failed] \(error)")
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
        guard state == .streaming, fastSessionToken != nil else { return }
        guard !data.isEmpty else { return }
        lastFrameCount += AVAudioFramePosition(frames)
        fastAccumulated.append(data)
        while fastAccumulated.count >= fastChunkBytes {
            let chunk = Data(fastAccumulated.prefix(fastChunkBytes))
            fastAccumulated.removeSubrange(0..<fastChunkBytes)
            enqueueFastChunk(chunk)
        }
    }

    private func enqueueFastChunk(_ data: Data) {
        fastQueue.append(data)
        drainFastQueueIfNeeded()
    }

    private func drainFastQueueIfNeeded() {
        guard !fastProcessing else { return }
        fastProcessing = true
        fastTask = Task { @MainActor [weak self] in
            await self?.processFastQueue()
        }
    }

    private func processFastQueue() async {
        let token = fastSessionToken
        while state == .streaming {
            if token == nil || token != fastSessionToken {
                break
            }
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
                if state != .streaming || token != fastSessionToken {
                    break
                }
                let now = CFAbsoluteTimeGetCurrent()
                if let last = lastPartialTimestamp {
                    let updateMs = Int((now - last) * 1000)
                    print("[update_rate] \(updateMs)ms")
                }
                lastPartialTimestamp = now
                print("[partial_len] \(text.count)")

                if text != lastPreviewText {
                    lastPreviewText = text
                    onPreviewText?(text)
                }
                let elapsedMs = Int((now - started) * 1000)
                if let latency {
                    print("[fast_asr_latency] server=\(latency)ms push=\(elapsedMs)ms")
                } else {
                    print("[fast_asr_latency] push=\(elapsedMs)ms")
                }
            } catch {
                print("[fast_asr_error] \(error)")
            }
        }
        fastProcessing = false
        fastTask = nil
    }
}
