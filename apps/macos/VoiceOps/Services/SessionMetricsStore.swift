import Foundation

protocol SessionMetricsRecording {
    func record(_ metric: SessionMetricV1) async
}

actor SessionMetricsStore: SessionMetricsRecording {
    static let shared = SessionMetricsStore()
    static let didRecordNotification = Notification.Name("inVoiceSessionMetricRecorded")

    private let fileManager: FileManager
    private let directoryURL: URL
    private let activeURL: URL
    private let maximumBytes: UInt64
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        maximumBytes: UInt64 = 50 * 1024 * 1024,
        retentionDays: Int = 14
    ) {
        self.fileManager = fileManager
        let directory = directoryURL ?? fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Logs/VoiceOps", isDirectory: true)
        self.directoryURL = directory
        self.activeURL = directory.appendingPathComponent("session_metrics.jsonl")
        self.maximumBytes = maximumBytes
        self.retentionInterval = TimeInterval(max(1, retentionDays) * 24 * 60 * 60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func record(_ metric: SessionMetricV1) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoded = try encoder.encode(metric) + Data([0x0A])
            try rotateIfNeeded(incomingBytes: UInt64(encoded.count))
            if !fileManager.fileExists(atPath: activeURL.path) {
                fileManager.createFile(atPath: activeURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: activeURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
            try cleanupExpiredFiles()
            NotificationCenter.default.post(name: Self.didRecordNotification, object: nil)
        } catch {
            NSLog("[metrics] write_failed error=%@", String(describing: error))
        }
    }

    /// Bounded, off-main-thread read. Never loads a 50 MB log into the UI process.
    func recentSummary() -> SessionSummary {
        guard let handle = try? FileHandle(forReadingFrom: activeURL) else { return SessionSummary() }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            let offset = length > 512 * 1024 ? length - 512 * 1024 : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var lines = data.split(separator: 0x0A)
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            let metrics = lines.compactMap { try? decoder.decode(SessionMetricV1.self, from: Data($0)) }
                .filter { $0.timestamp >= cutoff }
            return SessionSummary(metrics: metrics)
        } catch {
            return SessionSummary()
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) throws {
        guard let values = try? activeURL.resourceValues(forKeys: [.fileSizeKey]),
              UInt64(values.fileSize ?? 0) + incomingBytes > maximumBytes else {
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let rotatedURL = directoryURL.appendingPathComponent(
            "session_metrics_\(formatter.string(from: Date())).jsonl"
        )
        try fileManager.moveItem(at: activeURL, to: rotatedURL)
    }

    private func cleanupExpiredFiles() throws {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where file.lastPathComponent.hasPrefix("session_metrics_") {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values.contentModificationDate, modified < cutoff {
                try fileManager.removeItem(at: file)
            }
        }
    }
}
