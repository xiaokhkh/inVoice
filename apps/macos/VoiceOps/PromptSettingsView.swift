import SwiftUI

struct PromptSettingsView: View {
    @AppStorage(OfflineLLMClient.modelDefaultsKey) private var selectedModel = OfflineLLMClient.defaultModel
    @AppStorage(OfflineLLMClient.translationSystemPromptDefaultsKey) private var translationSystemPrompt = ""
    @AppStorage(OfflineLLMClient.translationUserPromptDefaultsKey) private var translationUserPrompt = ""
    @AppStorage(OfflineLLMClient.voiceSystemPromptDefaultsKey) private var voiceSystemPrompt = ""
    @AppStorage(OfflineLLMClient.voiceUserPromptDefaultsKey) private var voiceUserPrompt = ""
    @AppStorage(OfflineLLMClient.voicePolishSystemPromptDefaultsKey) private var voicePolishSystemPrompt = ""
    @AppStorage(OfflineLLMClient.voicePolishUserPromptDefaultsKey) private var voicePolishUserPrompt = ""
    @AppStorage(OfflineLLMClient.actionSystemPromptDefaultsKey) private var actionSystemPrompt = ""
    @AppStorage(OfflineLLMClient.actionUserPromptDefaultsKey) private var actionUserPrompt = ""
    @State private var installedModels = [OfflineLLMClient.defaultModel]
    @State private var modelStatusText = "检查中…"
    @State private var modelStatusColor = Color.secondary
    @State private var modelDetailsText = "正在连接这台 Mac 上的 Ollama"
    @State private var isRefreshingModel = false
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("本地模型")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Menu { Button("恢复全部默认提示词…") { confirmReset = true } } label: { Image(systemName: "ellipsis.circle") }
                        .help("更多选项").accessibilityLabel("更多模型选项")
                        .confirmationDialog("恢复全部默认提示词？自定义内容将被替换。", isPresented: $confirmReset) {
                            Button("恢复默认", role: .destructive) {
                            translationSystemPrompt = OfflineLLMClient.defaultTranslationSystemPrompt
                            translationUserPrompt = OfflineLLMClient.defaultTranslationUserPromptTemplate
                            voiceSystemPrompt = OfflineLLMClient.defaultVoiceSystemPrompt
                            voiceUserPrompt = OfflineLLMClient.defaultVoiceUserPromptTemplate
                            voicePolishSystemPrompt = OfflineLLMClient.defaultVoicePolishSystemPrompt
                            voicePolishUserPrompt = OfflineLLMClient.defaultVoicePolishUserPromptTemplate
                            actionSystemPrompt = OfflineLLMClient.defaultActionSystemPrompt
                            actionUserPrompt = OfflineLLMClient.defaultActionUserPromptTemplate
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("选择用于整理文字和对话的模型。更多选项按需展开。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                PromptSection(title: "本地模型", subtitle: "文字整理、翻译与助手共用这个模型。") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(modelStatusColor)
                                .frame(width: 9, height: 9)
                            Text(modelStatusText)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("刷新") {
                                Task { await refreshModelStatus() }
                            }
                            .disabled(isRefreshingModel)
                            .controlSize(.small)
                        }

                        Picker("模型", selection: $selectedModel) {
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

                PromptSection(title: "翻译", subtitle: "默认英文 → 简体中文，支持自定义。") {
                    PromptCard(
                        title: "系统提示词",
                        caption: "设置语气、约束与输出风格。",
                        text: $translationSystemPrompt,
                        minHeight: 190
                    )
                    PromptCard(
                        title: "输入模板",
                        caption: "用 {{text}} 代表选中的文字。",
                        text: $translationUserPrompt,
                        minHeight: 150
                    )
                }

                PromptSection(title: "英文润色", subtitle: "用于把中文语音转为英文，或润色英文。") {
                    PromptCard(
                        title: "系统提示词",
                        caption: "设置语音输入的处理方式。",
                        text: $voiceSystemPrompt,
                        minHeight: 190
                    )
                    PromptCard(
                        title: "输入模板",
                        caption: "用 {{text}} 代表识别到的语音内容。",
                        text: $voiceUserPrompt,
                        minHeight: 150
                    )
                }

                PromptSection(title: "轻度整理", subtitle: "保留输入语言，整理口头语和标点。") {
                    PromptCard(
                        title: "系统提示词",
                        caption: "保留语言与意思，仅优化表达。",
                        text: $voicePolishSystemPrompt,
                        minHeight: 170
                    )
                    PromptCard(
                        title: "输入模板",
                        caption: "用 {{text}} 代表识别到的语音内容。",
                        text: $voicePolishUserPrompt,
                        minHeight: 130
                    )
                }

                PromptSection(title: "行动摘要", subtitle: "把口述内容整理成背景与待办事项。") {
                    PromptCard(
                        title: "系统提示词",
                        caption: "设置行动摘要的结构与约束。",
                        text: $actionSystemPrompt,
                        minHeight: 170
                    )
                    PromptCard(
                        title: "输入模板",
                        caption: "用 {{text}} 代表口述内容。",
                        text: $actionUserPrompt,
                        minHeight: 140
                    )
                }
            }
            .padding(20)
        }
        .onAppear {
            if OfflineLLMClient.previousDefaultModels.contains(selectedModel) {
                selectedModel = OfflineLLMClient.defaultModel
            }
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
            if voicePolishSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voicePolishSystemPrompt = OfflineLLMClient.defaultVoicePolishSystemPrompt
            }
            if voicePolishUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voicePolishUserPrompt = OfflineLLMClient.defaultVoicePolishUserPromptTemplate
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
        modelStatusText = "检查中…"
        modelStatusColor = .secondary
        defer { isRefreshingModel = false }

        do {
            let status = try await OfflineLLMClient().modelStatus()
            installedModels = status.installedModels
            if status.isLoaded {
                modelStatusText = "已加载 · 可以使用"
                modelStatusColor = .green
            } else if status.isInstalled {
                modelStatusText = "已安装 · 首次使用时加载"
                modelStatusColor = .orange
            } else {
                modelStatusText = "尚未安装此模型"
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
                details.append("磁盘 \(formattedBytes(storageBytes))")
            }
            if let memoryBytes = status.memoryBytes {
                details.append("显存 \(formattedBytes(memoryBytes))")
            }
            modelDetailsText = details.joined(separator: " · ")
        } catch {
            modelStatusText = "本地文字服务未启动"
            modelStatusColor = .red
            modelDetailsText = "请先打开 Ollama，再点击刷新。"
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
    @State private var isExpanded = false

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title == "本地模型" {
                heading
                content
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(spacing: 12) { content }.padding(.top, 16)
                } label: { heading }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08)))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
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
