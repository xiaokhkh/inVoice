import SwiftUI

struct PromptSettingsView: View {
    @AppStorage(OfflineLLMClient.modelDefaultsKey) private var selectedModel = OfflineLLMClient.defaultModel
    @AppStorage(OfflineLLMClient.translationSystemPromptDefaultsKey) private var translationSystemPrompt = ""
    @AppStorage(OfflineLLMClient.translationUserPromptDefaultsKey) private var translationUserPrompt = ""
    @AppStorage(OfflineLLMClient.voiceSystemPromptDefaultsKey) private var voiceSystemPrompt = ""
    @AppStorage(OfflineLLMClient.voiceUserPromptDefaultsKey) private var voiceUserPrompt = ""
    @AppStorage(OfflineLLMClient.actionSystemPromptDefaultsKey) private var actionSystemPrompt = ""
    @AppStorage(OfflineLLMClient.actionUserPromptDefaultsKey) private var actionUserPrompt = ""
    @State private var installedModels = [OfflineLLMClient.defaultModel]
    @State private var modelStatusText = "Checking…"
    @State private var modelStatusColor = Color.secondary
    @State private var modelDetailsText = "Connecting to Ollama on 127.0.0.1:11434"
    @State private var isRefreshingModel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("LLM Prompts")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button("Reset All") {
                            translationSystemPrompt = OfflineLLMClient.defaultTranslationSystemPrompt
                            translationUserPrompt = OfflineLLMClient.defaultTranslationUserPromptTemplate
                            voiceSystemPrompt = OfflineLLMClient.defaultVoiceSystemPrompt
                            voiceUserPrompt = OfflineLLMClient.defaultVoiceUserPromptTemplate
                            actionSystemPrompt = OfflineLLMClient.defaultActionSystemPrompt
                            actionUserPrompt = OfflineLLMClient.defaultActionUserPromptTemplate
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("Tune how the local Ollama model translates text and handles voice input.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                PromptSection(title: "Local Model", subtitle: "The real Ollama model shared by every LLM feature.") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(modelStatusColor)
                                .frame(width: 9, height: 9)
                            Text(modelStatusText)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Refresh") {
                                Task { await refreshModelStatus() }
                            }
                            .disabled(isRefreshingModel)
                            .controlSize(.small)
                        }

                        Picker("Model", selection: $selectedModel) {
                            ForEach(modelChoices, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }

                        Text(modelDetailsText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                PromptSection(title: "Translation", subtitle: "Used when translating selected text.") {
                    PromptCard(
                        title: "System Prompt",
                        caption: "Defines tone, constraints, and output style.",
                        text: $translationSystemPrompt,
                        minHeight: 190
                    )
                    PromptCard(
                        title: "User Template",
                        caption: "Use `{{text}}` as the placeholder for the selected text.",
                        text: $translationUserPrompt,
                        minHeight: 150
                    )
                }

                PromptSection(title: "Voice", subtitle: "Used for spoken input processing.") {
                    PromptCard(
                        title: "System Prompt",
                        caption: "Sets the voice workflow behavior.",
                        text: $voiceSystemPrompt,
                        minHeight: 190
                    )
                    PromptCard(
                        title: "User Template",
                        caption: "Use `{{text}}` as the placeholder for the spoken input.",
                        text: $voiceUserPrompt,
                        minHeight: 150
                    )
                }

                PromptSection(title: "Action", subtitle: "Used when turning spoken notes into TODO items.") {
                    PromptCard(
                        title: "System Prompt",
                        caption: "Defines the action-summary structure and constraints.",
                        text: $actionSystemPrompt,
                        minHeight: 170
                    )
                    PromptCard(
                        title: "User Template",
                        caption: "Use `{{text}}` as the placeholder for the spoken note.",
                        text: $actionUserPrompt,
                        minHeight: 140
                    )
                }
            }
            .padding(20)
        }
        .onAppear {
            if translationSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translationSystemPrompt = OfflineLLMClient.defaultTranslationSystemPrompt
            }
            if translationUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translationUserPrompt = OfflineLLMClient.defaultTranslationUserPromptTemplate
            }
            if voiceSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceSystemPrompt = OfflineLLMClient.defaultVoiceSystemPrompt
            }
            if voiceUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceUserPrompt = OfflineLLMClient.defaultVoiceUserPromptTemplate
            }
            if actionSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                actionSystemPrompt = OfflineLLMClient.defaultActionSystemPrompt
            }
            if actionUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                actionUserPrompt = OfflineLLMClient.defaultActionUserPromptTemplate
            }
        }
        .task {
            await refreshModelStatus()
        }
        .onChange(of: selectedModel) { _ in
            Task { await refreshModelStatus() }
        }
    }

    private var modelChoices: [String] {
        Array(Set(installedModels + [selectedModel])).sorted()
    }

    @MainActor
    private func refreshModelStatus() async {
        guard !isRefreshingModel else { return }
        isRefreshingModel = true
        modelStatusText = "Checking…"
        modelStatusColor = .secondary
        defer { isRefreshingModel = false }

        do {
            let status = try await OfflineLLMClient().modelStatus()
            installedModels = status.installedModels
            if status.isLoaded {
                modelStatusText = "Running on GPU"
                modelStatusColor = .green
            } else if status.isInstalled {
                modelStatusText = "Installed · idle"
                modelStatusColor = .orange
            } else {
                modelStatusText = "Model not installed"
                modelStatusColor = .red
            }

            var details = [status.selectedModel]
            if let parameterSize = status.parameterSize {
                details.append(parameterSize)
            }
            if let quantization = status.quantization {
                details.append(quantization)
            }
            if let storageBytes = status.storageBytes {
                details.append("disk \(formattedBytes(storageBytes))")
            }
            if let memoryBytes = status.memoryBytes {
                details.append("GPU memory \(formattedBytes(memoryBytes))")
            }
            modelDetailsText = details.joined(separator: " · ")
        } catch {
            modelStatusText = "Ollama unavailable"
            modelStatusColor = .red
            modelDetailsText = "Start Ollama on 127.0.0.1:11434, then refresh."
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct PromptSection<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                content
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12))
        )
    }
}

private struct PromptCard: View {
    let title: String
    let caption: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18))
                )
        }
    }
}
