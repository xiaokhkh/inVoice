import Foundation
import Network

final class SidecarLauncher {
    static let shared = SidecarLauncher()

    struct InstallationStatus {
        let sidecarRootPath: String?
        let finalASREnvironmentReady: Bool
        let finalASRModelReady: Bool
        let fastASREnvironmentReady: Bool
        let fastASRModelReady: Bool

        var isReady: Bool {
            sidecarRootPath != nil
                && finalASREnvironmentReady
                && finalASRModelReady
                && fastASREnvironmentReady
                && fastASRModelReady
        }
    }

    struct Sidecar {
        let name: String
        let directory: String
        let script: String
        let port: Int
    }

    private let sidecars: [Sidecar] = [
        Sidecar(name: "asr_mlx", directory: "asr_mlx", script: "server.py", port: 8765),
        Sidecar(name: "fast_asr", directory: "fast_asr", script: "server.py", port: 8790),
    ]

    private var processes: [String: Process] = [:]
    private var logHandles: [String: FileHandle] = [:]
    private let checkQueue = DispatchQueue(label: "voiceops.sidecar.check")

    private init() {}

    func startAll() {
        Task { await startAllAsync() }
    }

    func stopAll() {
        for (_, process) in processes {
            if process.isRunning {
                process.terminate()
            }
        }
        processes.removeAll()
        for (_, handle) in logHandles {
            try? handle.close()
        }
        logHandles.removeAll()
    }

    func installationStatus() -> InstallationStatus {
        guard let root = findSidecarRoot() else {
            return InstallationStatus(
                sidecarRootPath: nil,
                finalASREnvironmentReady: false,
                finalASRModelReady: false,
                fastASREnvironmentReady: false,
                fastASRModelReady: false
            )
        }

        let finalASRDirectory = root.appendingPathComponent("asr_mlx", isDirectory: true)
        let fastASRDirectory = root.appendingPathComponent("fast_asr", isDirectory: true)
        let modelDirectory: URL
        if let customModelDirectory = ProcessInfo.processInfo.environment["FAST_ASR_MODEL_DIR"] {
            modelDirectory = URL(fileURLWithPath: customModelDirectory, isDirectory: true)
        } else {
            modelDirectory = root
                .deletingLastPathComponent()
                .appendingPathComponent("models/zipformer", isDirectory: true)
        }
        let requiredModelFiles = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt", "bpe.model"]

        return InstallationStatus(
            sidecarRootPath: root.path,
            finalASREnvironmentReady: hasVirtualEnvironment(in: finalASRDirectory),
            finalASRModelReady: hasFinalASRModel(),
            fastASREnvironmentReady: hasVirtualEnvironment(in: fastASRDirectory),
            fastASRModelReady: requiredModelFiles.allSatisfy { filename in
                FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(filename).path)
            }
        )
    }

    func logsDirectoryURL() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logs = library.appendingPathComponent("Logs/VoiceOps", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    private func startAllAsync() async {
        guard let root = findSidecarRoot() else {
            print("[sidecar] root_not_found")
            return
        }
        let repoRoot = root.deletingLastPathComponent()
        for sidecar in sidecars {
            let isUp = await isPortOpen(sidecar.port)
            if isUp {
                print("[sidecar] already_running \(sidecar.name)")
                continue
            }
            start(sidecar, root: root, repoRoot: repoRoot)
        }
    }

    private func start(_ sidecar: Sidecar, root: URL, repoRoot: URL) {
        let dir = root.appendingPathComponent(sidecar.directory, isDirectory: true)
        let scriptURL = dir.appendingPathComponent(sidecar.script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            print("[sidecar] script_missing \(sidecar.name) path=\(scriptURL.path)")
            return
        }
        guard let pythonURL = pythonExecutableURL(for: dir) else {
            print("[sidecar] python_missing \(sidecar.name)")
            return
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = dir
        process.environment = buildEnvironment(for: sidecar, root: root, repoRoot: repoRoot)
        let logURL = logFileURL(name: sidecar.name)
        if let handle = logHandle(for: logURL) {
            process.standardOutput = handle
            process.standardError = handle
            logHandles[sidecar.name] = handle
        }
        process.terminationHandler = { [weak self] proc in
            print("[sidecar] exited \(sidecar.name) code=\(proc.terminationStatus)")
            self?.processes.removeValue(forKey: sidecar.name)
        }

        do {
            try process.run()
            processes[sidecar.name] = process
            print("[sidecar] started \(sidecar.name) pid=\(process.processIdentifier)")
        } catch {
            print("[sidecar] start_failed \(sidecar.name) error=\(error)")
        }
    }

    private func buildEnvironment(for sidecar: Sidecar, root: URL, repoRoot: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if sidecar.name == "fast_asr" {
            let modelDir = repoRoot.appendingPathComponent("models/zipformer", isDirectory: true)
            if FileManager.default.fileExists(atPath: modelDir.path) {
                env["FAST_ASR_MODEL_DIR"] = modelDir.path
            }
        }
        return env
    }

    private func pythonExecutableURL(for sidecarDir: URL) -> URL? {
        if let custom = ProcessInfo.processInfo.environment["VOICEOPS_PYTHON_PATH"] {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let venvPython = sidecarDir.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }
        let venvPython3 = sidecarDir.appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: venvPython3.path) {
            return venvPython3
        }
        let systemPython = URL(fileURLWithPath: "/usr/bin/python3")
        if FileManager.default.isExecutableFile(atPath: systemPython.path) {
            return systemPython
        }
        return nil
    }

    private func hasVirtualEnvironment(in sidecarDirectory: URL) -> Bool {
        let python = sidecarDirectory.appendingPathComponent(".venv/bin/python")
        let python3 = sidecarDirectory.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.isExecutableFile(atPath: python.path)
            || FileManager.default.isExecutableFile(atPath: python3.path)
    }

    private func hasFinalASRModel() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let cacheRoot: URL
        if let customCache = environment["HF_HUB_CACHE"], !customCache.isEmpty {
            cacheRoot = URL(fileURLWithPath: customCache, isDirectory: true)
        } else if let huggingFaceHome = environment["HF_HOME"], !huggingFaceHome.isEmpty {
            cacheRoot = URL(fileURLWithPath: huggingFaceHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        } else {
            cacheRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        }
        let modelID = environment["ASR_MODEL_ID"] ?? "mlx-community/GLM-ASR-Nano-2512-8bit"
        let cacheName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshots = cacheRoot
            .appendingPathComponent(cacheName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        return FileManager.default.enumerator(atPath: snapshots.path)?.nextObject() != nil
    }

    private func findSidecarRoot() -> URL? {
        if let value = ProcessInfo.processInfo.environment["VOICEOPS_SIDECAR_ROOT"] {
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("sidecars"),
           FileManager.default.fileExists(atPath: resourceRoot.path) {
            return resourceRoot
        }

        if let configuredRoot = configuredSidecarRoot() {
            return configuredRoot
        }

        var cursor = Bundle.main.bundleURL
        for _ in 0..<6 {
            let candidate = cursor.deletingLastPathComponent().appendingPathComponent("sidecars")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return nil
    }

    private func configuredSidecarRoot() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configURL = support
            .appendingPathComponent("VoiceOps", isDirectory: true)
            .appendingPathComponent("sidecar-root")
        guard let value = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func logFileURL(name: String) -> URL {
        logsDirectoryURL().appendingPathComponent("sidecar_\(name).log")
    }

    private func logHandle(for url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch {
            print("[sidecar] log_open_failed path=\(url.path) error=\(error)")
            return nil
        }
    }

    private func isPortOpen(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let state = PortCheck()
            let connection = NWConnection(
                host: .ipv4(IPv4Address("127.0.0.1")!),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            @Sendable func finish(_ value: Bool) {
                state.finish(value, connection: connection, continuation: continuation)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: checkQueue)
            checkQueue.asyncAfter(deadline: .now() + 0.4) {
                finish(false)
            }
        }
    }
}

private final class PortCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func finish(
        _ value: Bool,
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}
