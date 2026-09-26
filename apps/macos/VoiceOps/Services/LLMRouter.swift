import Foundation

protocol DictationLLMRouting {
    func warmUp(mode: DictationPostProcessMode) async -> Int?
    func route(text: String, mode: DictationPostProcessMode) async -> LLMRouter.RoutedResult
}

final class LLMRouter: DictationLLMRouting {
    enum Action: String {
        case translate = "TRANSLATE"
        case polish = "POLISH"
        case direct = "DIRECT"
    }

    struct RoutedResult {
        let text: String
        let action: Action
        let reason: String?
        let offlineUsed: Bool
        let modelUsed: String
        let offlineLatencyMs: Int?
        let loadMs: Int?
        let promptEvalMs: Int?
        let generateMs: Int?
        let codexLatencyMs: Int?
    }

    private let offlineClient: OfflineLLMClient

    init(offlineClient: OfflineLLMClient = OfflineLLMClient()) {
        self.offlineClient = offlineClient
    }

    func warmUp(mode: DictationPostProcessMode) async -> Int? {
        let action = DictationPostProcessPolicy().action(for: mode)
        guard action.requiresLLM else { return 0 }
        return await offlineClient.warmUp()
    }

    func route(text: String, mode: DictationPostProcessMode) async -> RoutedResult {
        let postProcessAction = DictationPostProcessPolicy().action(for: mode)
        if postProcessAction == .direct {
            return RoutedResult(
                text: text,
                action: .direct,
                reason: nil,
                offlineUsed: false,
                modelUsed: "none",
                offlineLatencyMs: 0,
                loadMs: 0,
                promptEvalMs: 0,
                generateMs: 0,
                codexLatencyMs: nil
            )
        }

        let offlineStart = CFAbsoluteTimeGetCurrent()
        var offlineLatency: Int?
        let modelName = offlineClient.modelName

        do {
            let profile: OfflineLLMClient.PromptProfile = mode == .polishSameLanguage
                ? .voicePolish
                : .voice
            let generation = try await offlineClient.translateDetailed(text: text, profile: profile)
            offlineLatency = Int((CFAbsoluteTimeGetCurrent() - offlineStart) * 1000)
            let finalText = generation.text.isEmpty ? text : generation.text
            logDecision(
                offlineUsed: true,
                action: mode == .polishSameLanguage ? .polish : .translate,
                reason: nil,
                modelUsed: modelName,
                offlineLatency: offlineLatency,
                codexLatency: nil
            )
            return RoutedResult(
                text: finalText,
                action: mode == .polishSameLanguage ? .polish : .translate,
                reason: nil,
                offlineUsed: true,
                modelUsed: modelName,
                offlineLatencyMs: offlineLatency,
                loadMs: generation.loadMs,
                promptEvalMs: generation.promptEvalMs,
                generateMs: generation.generateMs,
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
                loadMs: nil,
                promptEvalMs: nil,
                generateMs: nil,
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
