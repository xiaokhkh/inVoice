import Foundation

final class LLMRouter {
    enum Action: String {
        case translate = "TRANSLATE"
        case direct = "DIRECT"
    }

    struct RoutedResult {
        let text: String
        let action: Action
        let reason: String?
        let offlineUsed: Bool
        let modelUsed: String
        let offlineLatencyMs: Int?
        let codexLatencyMs: Int?
    }

    private let offlineClient: OfflineLLMClient

    init(offlineClient: OfflineLLMClient = OfflineLLMClient()) {
        self.offlineClient = offlineClient
    }

    func warmUp() async {
        await offlineClient.warmUp()
    }

    func route(text: String) async -> RoutedResult {
        let offlineStart = CFAbsoluteTimeGetCurrent()
        var offlineLatency: Int?
        let modelName = offlineClient.modelName

        do {
            let translated = try await offlineClient.translate(text: text, profile: .voice)
            offlineLatency = Int((CFAbsoluteTimeGetCurrent() - offlineStart) * 1000)
            let finalText = translated.isEmpty ? text : translated
            logDecision(
                offlineUsed: true,
                action: .translate,
                reason: nil,
                modelUsed: modelName,
                offlineLatency: offlineLatency,
                codexLatency: nil
            )
            return RoutedResult(
                text: finalText,
                action: .translate,
                reason: nil,
                offlineUsed: true,
                modelUsed: modelName,
                offlineLatencyMs: offlineLatency,
                codexLatencyMs: nil
            )
        } catch {
            offlineLatency = Int((CFAbsoluteTimeGetCurrent() - offlineStart) * 1000)
            logDecision(
                offlineUsed: false,
                action: .direct,
                reason: "offline_failed",
                modelUsed: modelName,
                offlineLatency: offlineLatency,
                codexLatency: nil
            )
            return RoutedResult(
                text: text,
                action: .direct,
                reason: "offline_failed",
                offlineUsed: false,
                modelUsed: modelName,
                offlineLatencyMs: offlineLatency,
                codexLatencyMs: nil
            )
        }
    }

    private func logDecision(
        offlineUsed: Bool,
        action: Action,
        reason: String?,
        modelUsed: String,
        offlineLatency: Int?,
        codexLatency: Int?
    ) {
        print("[llm] offline_llm_used=\(offlineUsed)")
        print("[llm] decision_action=\(action.rawValue)")
        if let reason, !reason.isEmpty {
            print("[llm] escalation_reason=\(reason)")
        }
        print("[llm] model_used=\(modelUsed)")
        if let offlineLatency {
            print("[llm] latency_offline_ms=\(offlineLatency)")
        }
        if let codexLatency {
            print("[llm] latency_codex_ms=\(codexLatency)")
        }
    }
}
