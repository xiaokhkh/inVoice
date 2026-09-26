import Foundation
import Network

final class SidecarLauncher {
    static let shared = SidecarLauncher()

    let localToken: String

    private static let localTokenDefaultsKey = "voiceops.sidecar.localToken"

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
    private var restartAttempts: [String: Int] = [:]
    private var isStopping = false
    private let stateLock = NSLock()
    private let checkQueue = DispatchQueue(label: "voiceops.sidecar.check")

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.localTokenDefaultsKey), !stored.isEmpty {
            localToken = stored
        } else {
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            defaults.set(generated, forKey: Self.localTokenDefaultsKey)
            localToken = generated
        }
    }

    func startAll() {
        stateLock.withLock {
            isStopping = false
            restartAttempts.removeAll()
        }
        Task { await startAllAsync() }
    }

    func stopAll() {
        let state = stateLock.withLock { () -> ([Process], [FileHandle]) in
            isStopping = true
            let running = Array(processes.values)
            let handles = Array(logHandles.values)
            processes.removeAll()
            logHandles.removeAll()
            restartAttempts.removeAll()
            return (running, handles)
        }
        for process in state.0 {
            if process.isRunning {
                process.terminate()
            }
        }
        for handle in state.1 {
            try? handle.close()
        }
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
            if await isExpectedServiceUp(sidecar) {
                print("[sidecar] already_running \(sidecar.name)")
                continue
            }
            if await isPortOpen(sidecar.port) {
                print("[sidecar] port_conflict \(sidecar.name) port=\(sidecar.port)")
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
        let mayStart = stateLock.withLock {
            !isStopping && processes[sidecar.name] == nil
        }
        guard mayStart else { return }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = dir
        process.environment = buildEnvironment(for: sidecar, root: root, repoRoot: repoRoot)
        let logURL = logFileURL(name: sidecar.name)
        if let handle = logHandle(for: logURL) {
            process.standardOutput = handle
            process.standardError = handle
            stateLock.withLock {
                logHandles[sidecar.name] = handle
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.handleTermination(
                sidecar,
                root: root,
                repoRoot: repoRoot,
                process: terminatedProcess
            )
        }

        do {
            stateLock.withLock {
                processes[sidecar.name] = process
            }
            try process.run()
            print("[sidecar] started \(sidecar.name) pid=\(process.processIdentifier)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self, weak process] in
                guard let self, let process, process.isRunning else { return }
                self.stateLock.withLock {
                    if self.processes[sidecar.name] === process {
                        self.restartAttempts[sidecar.name] = 0
                    }
                }
            }
        } catch {
            stateLock.withLock {
                if processes[sidecar.name] === process {
                    processes.removeValue(forKey: sidecar.name)
                }
                if let handle = logHandles.removeValue(forKey: sidecar.name) {
                    try? handle.close()
                }
            }
            print("[sidecar] start_failed \(sidecar.name) error=\(error)")
            scheduleRestart(sidecar, root: root, repoRoot: repoRoot)
        }
    }

    private func handleTermination(
        _ sidecar: Sidecar,
        root: URL,
        repoRoot: URL,
        process: Process
    ) {
        let shouldRestart = stateLock.withLock { () -> Bool in
            if processes[sidecar.name] === process {
                processes.removeValue(forKey: sidecar.name)
            }
            if let handle = logHandles.removeValue(forKey: sidecar.name) {
                try? handle.close()
            }
            return !isStopping
        }
        print("[sidecar] exited \(sidecar.name) code=\(process.terminationStatus)")
        if shouldRestart {
            scheduleRestart(sidecar, root: root, repoRoot: repoRoot)
        }
    }

    private func scheduleRestart(_ sidecar: Sidecar, root: URL, repoRoot: URL) {
        let attempt = stateLock.withLock { () -> Int? in
            guard !isStopping else { return nil }
            let next = (restartAttempts[sidecar.name] ?? 0) + 1
            guard next <= 3 else { return nil }
            restartAttempts[sidecar.name] = next
            return next
        }
        guard let attempt else {
            print("[sidecar] restart_exhausted \(sidecar.name)")
            return
        }
        let delay = 1 << (attempt - 1)
        print("[sidecar] restart_scheduled \(sidecar.name) attempt=\(attempt) delay=\(delay)s")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            self?.start(sidecar, root: root, repoRoot: repoRoot)
        }
    }

    private func buildEnvironment(for sidecar: Sidecar, root: URL, repoRoot: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["VOICEOPS_LOCAL_TOKEN"] = localToken
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
        rotateAndCleanLog(at: url)
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

    private func rotateAndCleanLog(at activeURL: URL) {
        let fileManager = FileManager.default
        let maximumBytes = 50 * 1024 * 1024
        if let values = try? activeURL.resourceValues(forKeys: [.fileSizeKey]),
           (values.fileSize ?? 0) >= maximumBytes {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = activeURL.deletingPathExtension().lastPathComponent
            let rotated = activeURL.deletingLastPathComponent().appendingPathComponent(
                "\(stem)_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).log"
            )
            try? fileManager.moveItem(at: activeURL, to: rotated)
        }

        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        guard let files = try? fileManager.contentsOfDirectory(
            at: activeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("sidecar_") && file != activeURL {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
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

    private func isExpectedServiceUp(_ sidecar: Sidecar) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(sidecar.port)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let expectedService = sidecar.name == "fast_asr" ? "voiceops-fast-asr" : "voiceops-asr-mlx"
        return payload["service"] as? String == expectedService
            && payload["protocol_version"] as? Int == 1
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
