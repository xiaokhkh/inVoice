import Foundation
import Combine

@MainActor
final class SelectionTranslationViewModel: ObservableObject {
    struct ChatMessage: Identifiable, Equatable {
        enum Role {
            case user
            case assistant
        }

        enum Kind {
            case selection
            case chat
        }

        let id = UUID()
        let role: Role
        var content: String
        let kind: Kind
    }

    enum State: Equatable {
        case idle
        case translating
        case ready
        case error(String)
    }

    @Published var state: State = .idle
    @Published var messages: [ChatMessage] = []
    @Published var composerText: String = ""
    @Published private(set) var selectedText: String = ""
    @Published private(set) var captureSource: SelectionCaptureSource?
    @Published private(set) var composerFocusRequest = 0

    typealias StreamHandler = @MainActor ([OfflineLLMClient.ChatMessage], @escaping @MainActor (String) -> Void) async throws -> String
    private let stream: StreamHandler
    private var bufferedDelta = ""
    private var flushTask: Task<Void, Never>?

    init(stream: StreamHandler? = nil) {
        self.stream = stream ?? { messages, onDelta in
            try await OfflineLLMClient().chatStream(messages: messages, profile: .assistant, onDelta: onDelta)
        }
    }
    private var task: Task<Void, Never>?
    private var pendingAssistantID: UUID?

    func start(selection: SelectionCaptureResult) {
        switch selection {
        case .success(let text, let source):
            resetConversation()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .error("没有可用的选中文字。")
                return
            }
            selectedText = trimmed
            captureSource = source
            sendUserMessage(trimmed)
        case .empty:
            requestComposerFocus()
        case .failure:
            state = .error(selection.userMessage)
        }
    }

    func cancel() {
        stopGenerating()
        task?.cancel()
        task = nil
        pendingAssistantID = nil
    }

    func sendComposerMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .translating else { return }
        composerText = ""
        sendUserMessage(text, kind: .chat)
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    func retryTranslation() {
        guard let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let message = messages[index]
        messages = Array(messages.prefix(index))
        sendUserMessage(message.content, kind: message.kind)
    }

    func newConversation() {
        resetConversation()
        requestComposerFocus()
    }

    func stopGenerating() {
        guard state == .translating else { return }
        task?.cancel()
        task = nil
        flushDelta(assistantID: pendingAssistantID)
        if let pendingAssistantID,
           let index = messages.firstIndex(where: { $0.id == pendingAssistantID }),
           messages[index].content.isEmpty {
            messages.remove(at: index)
        }
        pendingAssistantID = nil
        state = messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) ? .ready : .idle
    }

    var lastAssistantText: String? {
        messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
    }

    #if DEBUG
    func loadPreview(selectedText: String, translation: String) {
        cancel()
        self.selectedText = selectedText
        captureSource = .copyFallback
        messages = [
            ChatMessage(role: .user, content: selectedText, kind: .selection),
            ChatMessage(role: .assistant, content: translation, kind: .chat),
        ]
        composerText = ""
        pendingAssistantID = nil
        state = .ready
    }
    #endif

    private func sendUserMessage(_ text: String, kind: ChatMessage.Kind = .selection) {
        task?.cancel()
        task = nil

        let message = ChatMessage(role: .user, content: text, kind: kind)
        messages.append(message)
        let assistant = ChatMessage(role: .assistant, content: "", kind: .chat)
        messages.append(assistant)
        pendingAssistantID = assistant.id
        state = .translating
        task = Task { @MainActor [weak self] in
            await self?.runConversation()
        }
    }

    private func resetConversation() {
        flushTask?.cancel()
        flushTask = nil
        bufferedDelta = ""
        task?.cancel()
        task = nil
        state = .idle
        messages = []
        composerText = ""
        selectedText = ""
        captureSource = nil
        pendingAssistantID = nil
    }

    private func runConversation() async {
        guard !Task.isCancelled else { return }
        let assistantID = pendingAssistantID
        do {
            let payload = messages.filter { message in
                !(message.role == .assistant && message.content.isEmpty)
            }.map { message in
                let content: String
                if message.role == .user, message.kind == .selection {
                    content = """
                    Translate the selected English text into Simplified Chinese. Preserve code, paths, URLs, commands, Markdown structure, and established technical terms. Return only the translation.

                    Selected text:
                    \(message.content)
                    """
                } else {
                    content = message.content
                }
                return OfflineLLMClient.ChatMessage(
                    role: message.role == .user ? "user" : "assistant",
                    content: content,
                    applyTemplate: false
                )
            }
            let translated = try await stream(payload) { [weak self] delta in
                self?.appendAssistantDelta(delta, assistantID: assistantID)
            }
            guard !Task.isCancelled, pendingAssistantID == assistantID else { return }
            finalizeAssistantMessage(translated, assistantID: assistantID)
            state = .ready
        } catch {
            guard !Task.isCancelled, pendingAssistantID == assistantID else { return }
            flushDelta(assistantID: assistantID)
            pendingAssistantID = nil
            state = .error("暂时无法回复，请稍后重试。可在设置中检查本地模型。")
        }
    }

    private func appendAssistantDelta(_ delta: String, assistantID: UUID?) {
        guard let assistantID, pendingAssistantID == assistantID else { return }
        bufferedDelta += delta
        guard flushTask == nil else { return }
        // Cap view/layout work at 25 updates per second when a model emits token bursts.
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            self?.flushDelta(assistantID: assistantID)
        }
    }

    private func flushDelta(assistantID: UUID?) {
        flushTask?.cancel()
        flushTask = nil
        guard let assistantID, pendingAssistantID == assistantID,
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if !bufferedDelta.isEmpty { messages[index].content += bufferedDelta }
        bufferedDelta = ""
    }

    private func finalizeAssistantMessage(_ fullText: String, assistantID: UUID?) {
        flushTask?.cancel()
        flushTask = nil
        bufferedDelta = ""
        guard let assistantID, pendingAssistantID == assistantID else { return }
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content = fullText
        pendingAssistantID = nil
    }
}
