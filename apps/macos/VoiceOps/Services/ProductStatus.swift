import AppKit
import Combine
import Foundation

@MainActor
final class ProductStatus: ObservableObject {
    enum Availability: Equatable {
        case checking, ready, unavailable
        var title: String {
            switch self {
            case .checking: return "检查中"
            case .ready: return "已就绪"
            case .unavailable: return "待恢复"
            }
        }
    }

    @Published private(set) var finalASR: Availability = .checking
    @Published private(set) var streamingASR: Availability = .checking
    @Published private(set) var languageModel: Availability = .checking
    @Published private(set) var permissionsReady = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStarting = true
    @Published private(set) var summary = SessionSummary()
    @Published private(set) var checkedAt: Date?
    @Published var phase = "准备就绪"
    private var observers = Set<AnyCancellable>()

    static let shared = ProductStatus()

    private init() {
        NotificationCenter.default.publisher(for: SessionMetricsStore.didRecordNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.refreshSummary() }
            }.store(in: &observers)
    }

    var canDictate: Bool { permissionsReady && finalASR == .ready }

    func waitForStartup() async {
        defer { isStarting = false }
        for _ in 0..<15 {
            await refresh()
            if finalASR == .ready && streamingASR == .ready { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        permissionsReady = Permissions.hasMicrophoneAccess()
            && Permissions.hasAccessibility() && Permissions.hasInputMonitoring()
        let token = SidecarLauncher.shared.localToken
        async let final = Self.checkService(port: 8765, name: "voiceops-asr-mlx", token: token)
        async let streaming = Self.checkService(port: 8790, name: "voiceops-fast-asr", token: token)
        async let llm = Self.checkLanguageModel(model: OfflineLLMClient().modelName)
        async let metrics = SessionMetricsStore.shared.recentSummary()
        let results = await (final, streaming, llm, metrics)
        finalASR = results.0 ? .ready : .unavailable
        streamingASR = results.1 ? .ready : .unavailable
        languageModel = results.2 ? .ready : .unavailable
        summary = results.3
        checkedAt = Date()
    }

    func refreshSummary() async {
        summary = await SessionMetricsStore.shared.recentSummary()
    }

    func recover() async {
        SidecarLauncher.shared.startAll()
        await refresh()
        // A cold model needs time to load. Poll only for this explicit recovery.
        for _ in 0..<10 {
            if finalASR == .ready && streamingASR == .ready { break }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await refresh()
        }
    }

    nonisolated private static func checkService(port: Int, name: String, token: String) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(LocalServiceHealth.self, from: data) else { return false }
        return health.isReady(expectedService: name)
    }

    nonisolated private static func checkLanguageModel(model: String) async -> Bool {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else { return false }
        return models.contains {
            guard let name = $0["name"] as? String else { return false }
            return name == model || name == model + ":latest" || name + ":latest" == model
        }
    }
}
