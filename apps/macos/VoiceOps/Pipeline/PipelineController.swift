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
    private var targetApp: NSRunningApplication?
    private var activeSession: ActiveSession?
    private var manualTask: Task<Void, Never>?
    private var polishTask: Task<Void, Never>?

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
        manualTask = nil
        polishTask = nil
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
            defer { try? FileManager.default.removeItem(at: wavURL) }
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
            defer { try? FileManager.default.removeItem(at: wavURL) }
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
