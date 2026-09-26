import Foundation

@main
struct AssistantExperienceSmoke {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "AssistantExperienceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(false, "assistant did not settle")
        }
        var payload: [OfflineLLMClient.ChatMessage] = []
        let completed = SelectionTranslationViewModel { messages, delta in
            payload = messages
            delta("Hello ")
            delta("world")
            return "Hello world"
        }
        completed.composerText = "Draft"
        completed.start(selection: .empty(.noSelection))
        try check(completed.composerText == "Draft", "opening preserves draft")
        completed.sendComposerMessage()
        try await waitFor { completed.state == .ready }
        try check(completed.lastAssistantText == "Hello world", "final text includes buffered tail exactly once")
        try check(payload.first?.content == "Draft", "ordinary conversation stays ordinary")
        completed.composerText = "Follow-up draft"
        completed.cancel()
        completed.start(selection: .empty(.clipboardUnchanged))
        try check(completed.messages.count == 2 && completed.composerText == "Follow-up draft" && completed.state == .ready, "close and reopen preserve conversation and draft")
        completed.start(selection: .success(text: "Selected English", source: .accessibilitySelectedText))
        try await waitFor { completed.state == .ready }
        try check(completed.messages.count == 2 && payload.first?.content.contains("Selected English") == true && payload.first?.content.contains("Translate") == true, "new selection starts translation")

        var emit: (@MainActor (String) -> Void)?
        var finish: CheckedContinuation<String, Error>?
        let streaming = SelectionTranslationViewModel { _, delta in
            emit = delta
            return try await withCheckedThrowingContinuation { finish = $0 }
        }
        streaming.composerText = "Start"
        streaming.sendComposerMessage()
        try await waitFor { emit != nil }
        for _ in 0..<100 { emit?("a") }
        try check(streaming.messages.last?.content.isEmpty == true, "burst updates are coalesced before layout")
        streaming.cancel()
        try check(streaming.lastAssistantText == String(repeating: "a", count: 100) && streaming.state == .ready, "close flushes partial response and unlocks composer")
        streaming.newConversation()
        emit?("late token")
        finish?.resume(returning: "late completion")
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(streaming.messages.isEmpty && streaming.state == .idle, "cancelled response cannot enter a new conversation")

        var attempts = 0
        let retry = SelectionTranslationViewModel { _, delta in
            attempts += 1
            if attempts == 1 { delta("partial"); throw URLError(.cannotConnectToHost) }
            delta("complete"); return "complete"
        }
        retry.composerText = "Retry me"
        retry.sendComposerMessage()
        try await waitFor { if case .error = retry.state { return true }; return false }
        try check(retry.lastAssistantText == "partial", "errors keep buffered output")
        retry.retryTranslation()
        try await waitFor { retry.state == .ready }
        try check(retry.messages.count == 2 && retry.lastAssistantText == "complete", "retry replaces failed turn")
        print("PASS: assistant drafts, reopen, selection translation, buffered stream, cancellation, late output, error recovery and retry")
    }
}
