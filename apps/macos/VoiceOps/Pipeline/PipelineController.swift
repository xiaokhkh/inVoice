import AppKit
import AVFoundation
import Foundation

@MainActor
final class PipelineController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case generating
        case ready
        case error(String)
    }

    private enum ActiveSession {
        case manual
        case streaming
        case polish
    }

    @Published var state: State = .idle
    @Published var mode: Mode = .polish
    @Published var transcript: String = ""
    @Published var output: String = ""

    private let asr = ASRClient()
    private let llm = OfflineLLMClient()
    private let injector = InputInjector()
    private let audio = AudioCaptureService()
    private let streamingStabilizer = TextStabilizer(confirmations: 2)
    private var targetApp: NSRunningApplication?
    private var activeSession: ActiveSession?
    private var endRequested = false
    private let chunkDuration: TimeInterval = 2.0
    private var manualTask: Task<Void, Never>?
    private var polishTask: Task<Void, Never>?
    private var streamingStartTask: Task<Void, Never>?
    private var streamingStopTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var streamingTickPending = false
    private var streamingForcePending = false
    private var lastStreamingFrameCount: AVAudioFramePosition = 0

    func toggleRecord() {
        switch state {
        case .idle, .ready, .error:
            guard manualTask == nil else { return }
            manualTask = Task { @MainActor [weak self] in
                await self?.startRecording()
                self?.manualTask = nil
            }
        case .recording:
            guard manualTask == nil else { return }
            manualTask = Task { @MainActor [weak self] in
                await self?.stopAndProcess()
                self?.manualTask = nil
            }
        default:
            break
        }
    }

    func cancel() {
        if case .recording = state {
            audio.cancel()
        }
        manualTask?.cancel()
        polishTask?.cancel()
        streamingStartTask?.cancel()
        streamingStopTask?.cancel()
        streamingTask?.cancel()
        manualTask = nil
        polishTask = nil
        streamingStartTask = nil
        streamingStopTask = nil
        streamingTask = nil
        streamingTickPending = false
        streamingForcePending = false
        lastStreamingFrameCount = 0
        streamingStabilizer.reset()
        endRequested = false
        activeSession = nil
        transcript = ""
        output = ""
        state = .idle
        targetApp = nil
        audio.resetStreamingState()
    }

    func insertToFocusedApp() {
        guard case .ready = state else { return }
        let text = output.isEmpty ? transcript : output
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let didInject = injector.insertViaPaste(text)
            if !didInject {
                _ = injector.insertViaTyping(text)
            }
            state = .idle
            targetApp = nil
        }
    }

    func startStreaming() {
        guard streamingStartTask == nil else { return }
        streamingStartTask = Task { @MainActor [weak self] in
            await self?.startStreamingSession()
            self?.streamingStartTask = nil
        }
    }

    func stopStreaming() {
        guard streamingStopTask == nil else { return }
        streamingStopTask = Task { @MainActor [weak self] in
            await self?.stopStreamingSession()
            self?.streamingStopTask = nil
        }
    }

    func startPolishRecording() {
        guard polishTask == nil else { return }
        polishTask = Task { @MainActor [weak self] in
            await self?.startPolishSession()
            self?.polishTask = nil
        }
    }

    func stopPolishRecording() {
        guard polishTask == nil else { return }
        polishTask = Task { @MainActor [weak self] in
            await self?.stopPolishSession()
            self?.polishTask = nil
        }
    }

    private func startRecording() async {
        let granted = await Permissions.requestMicrophoneIfNeeded()
        guard granted else {
            state = .error("Microphone permission denied")
            return
        }

        transcript = ""
        output = ""

        targetApp = nil

        do {
            try audio.start(streaming: false)
            activeSession = .manual
            state = .recording
        } catch {
            state = .error("Audio start failed: \(error)")
        }
    }

    private func stopAndProcess() async {
        do {
            let wavURL = try audio.stop()
            state = .transcribing
            transcript = try await asr.transcribe(wavURL: wavURL)

            state = .generating
            output = try await llm.generate(mode: mode, text: transcript)

            state = .ready
            activeSession = nil
        } catch {
            state = .error("Pipeline failed: \(error)")
        }
    }

    private func startStreamingSession() async {
        switch state {
        case .idle, .ready, .error:
            break
        default:
            return
        }
        let granted = await Permissions.requestMicrophoneIfNeeded()
        guard granted else {
            state = .error("Microphone permission denied")
            return
        }

        transcript = ""
        output = ""
        activeSession = .streaming
        endRequested = false
        streamingTickPending = false
        streamingForcePending = false
        lastStreamingFrameCount = 0
        streamingStabilizer.reset()

        targetApp = nil

        do {
            try audio.start(streaming: true, chunkDuration: chunkDuration) { [weak self] in
                self?.handleStreamingTick(force: false)
            }
            state = .recording
            print("[stream] start")
        } catch {
            state = .error("Audio start failed: \(error)")
        }
    }

    private func stopStreamingSession() async {
        guard activeSession == .streaming else { return }
        endRequested = true
        do {
            try audio.stopStreaming()
        } catch {
            state = .error("Audio stop failed: \(error)")
            finishStreaming(resetAudio: true)
            return
        }
        handleStreamingTick(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.endRequested, self.streamingTask == nil {
                self.finishStreaming(resetAudio: true)
            }
        }
        print("[stream] stop")
    }

    private func finishStreaming(resetAudio: Bool) {
        endRequested = false
        activeSession = nil
        state = .idle
        targetApp = nil
        if resetAudio {
            audio.resetStreamingState()
        }
    }

    private func handleStreamingTick(force: Bool) {
        guard activeSession == .streaming else { return }
        if force {
            streamingForcePending = true
        }
        if streamingTask != nil {
            streamingTickPending = true
            return
        }
        let shouldForce = streamingForcePending
        streamingForcePending = false
        streamingTask = Task { @MainActor [weak self] in
            await self?.runStreamingTranscription(force: shouldForce)
        }
    }

    private func runStreamingTranscription(force: Bool) async {
        defer {
            streamingTask = nil
            let reschedule = streamingTickPending || streamingForcePending
            let nextForce = streamingForcePending
            streamingTickPending = false
            streamingForcePending = false
            if reschedule {
                handleStreamingTick(force: nextForce)
            } else if endRequested {
                finishStreaming(resetAudio: true)
            }
        }

        do {
            guard let snapshot = try await audio.snapshotStreamingAudio() else { return }
            let url = snapshot.0
            let frameCount = snapshot.1
            if frameCount == lastStreamingFrameCount, !force {
                try? FileManager.default.removeItem(at: url)
                return
            }
            lastStreamingFrameCount = frameCount

            let text = try await asr.transcribe(wavURL: url)
            try? FileManager.default.removeItem(at: url)
            await appendStreamingText(text, forceCommit: force)
        } catch {
            state = .error("Streaming failed: \(error)")
            endRequested = false
        }
    }

    private func appendStreamingText(_ text: String, forceCommit: Bool) async {
        guard activeSession == .streaming else { return }
        let delta = forceCommit
            ? streamingStabilizer.forceCommit(text)
            : streamingStabilizer.update(text)
        guard !delta.isEmpty else { return }
        transcript += delta

        let didInject = injector.insertViaPaste(delta, restoreClipboard: false)
        if !didInject {
            _ = injector.insertViaTyping(delta)
        }
        print("[stream] asr=\(text.count) delta=\(delta.count) force=\(forceCommit)")
    }

    private func startPolishSession() async {
        switch state {
        case .idle, .ready, .error:
            break
        default:
            return
        }
        let granted = await Permissions.requestMicrophoneIfNeeded()
        guard granted else {
            state = .error("Microphone permission denied")
            return
        }

        transcript = ""
        output = ""
        activeSession = .polish

        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = app
        } else {
            targetApp = nil
        }

        do {
            try audio.start(streaming: false)
            state = .recording
        } catch {
            state = .error("Audio start failed: \(error)")
        }
    }

    private func stopPolishSession() async {
        guard activeSession == .polish else { return }
        do {
            let wavURL = try audio.stop()
            state = .transcribing
            transcript = try await asr.transcribe(wavURL: wavURL)

            state = .generating
            output = try await llm.generate(mode: .polish, text: transcript)

            let text = output.isEmpty ? transcript : output
            let didInject = injector.insertViaPaste(text)
            if !didInject {
                _ = injector.insertViaTyping(text)
            }
            state = .idle
            activeSession = nil
        } catch {
            state = .error("Pipeline failed: \(error)")
        }
    }
}
