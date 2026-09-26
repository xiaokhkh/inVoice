import SwiftUI

extension DictationPostProcessMode {
    var displayTitle: String {
        switch self {
        case .direct: return "原样转写"
        case .polishSameLanguage: return "轻度整理"
        case .translateAndPolish: return "英文润色"
        }
    }
    var displayDetail: String {
        switch self {
        case .direct: return "说什么，就写什么。跳过文字整理，等待更短。"
        case .polishSameLanguage: return "保留说话的语言，整理标点与口头语。"
        case .translateAndPolish: return "中文转成自然英文；英文则优化表达。"
        }
    }
    var example: String {
        switch self {
        case .direct: return "嗯，那个周五之前把这个方案发给我。"
        case .polishSameLanguage: return "周五之前把这个方案发给我。"
        case .translateAndPolish: return "Please send me the proposal by Friday."
        }
    }
    var icon: String {
        switch self {
        case .direct: return "text.alignleft"
        case .polishSameLanguage: return "wand.and.stars"
        case .translateAndPolish: return "character.bubble"
        }
    }
}

struct DictationSettingsView: View {
    @AppStorage(DictationASRMode.defaultsKey) private var asrModeRaw = DictationASRMode.defaultValue.rawValue
    @AppStorage(DictationPostProcessMode.defaultsKey) private var postProcessModeRaw = DictationPostProcessMode.defaultValue.rawValue
    @AppStorage(DictationPreferences.streamingFinalsApprovedKey) private var streamingFinalsApproved = false
    @ObservedObject private var status = ProductStatus.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PreferencesHeader(title: "说出来，就是你想要的样子", subtitle: "选择适合当前场景的输出方式。下一次听写立即生效。")
                VStack(alignment: .leading, spacing: 12) {
                    Text("文字输出").font(.headline)
                    ForEach([DictationPostProcessMode.translateAndPolish, .polishSameLanguage, .direct], id: \.rawValue) { mode in
                        modeRow(mode)
                    }
                }
                SectionCard(title: "效果示例", subtitle: "示例用于说明输出风格，实际文字由你的录音决定。") {
                    Text("你说").font(.caption).foregroundStyle(.secondary)
                    Text("“嗯，那个周五之前把这个方案发给我。”").font(.system(size: 14))
                    Divider().padding(.vertical, 3)
                    Text("\(selectedMode.displayTitle)后").font(.caption).foregroundStyle(.indigo)
                    Text(selectedMode.example).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                }
                if selectedMode != .direct && status.languageModel == .unavailable {
                    Label("文字整理模型尚未就绪。听写会先返回原文；可到「本地 AI」检查模型。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                SectionCard(title: "识别与速度", subtitle: "实时预览让你及时看到内容，最终识别保证完整性。") {
                    if streamingFinalsApproved {
                        Picker("识别模式", selection: $asrModeRaw) {
                            Text("准确优先").tag(DictationASRMode.accurate.rawValue)
                            Text("速度优先").tag(DictationASRMode.fast.rawValue)
                            Text("自动平衡").tag(DictationASRMode.adaptive.rawValue)
                        }
                    } else {
                        Label("准确优先", systemImage: "checkmark.seal")
                            .font(.system(size: 14, weight: .medium))
                    }
                    Text("需要更快出字时，可选择「原样转写」。首次使用可能需要等待模型加载，之后会更快。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Label("只有发起录音时才使用麦克风，松开后只投递一次文字。", systemImage: "mic.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .onAppear {
            if !streamingFinalsApproved { asrModeRaw = DictationASRMode.accurate.rawValue }
            if DictationPostProcessMode(rawValue: postProcessModeRaw) == nil {
                postProcessModeRaw = DictationPostProcessMode.defaultValue.rawValue
            }
        }
    }

    private var selectedMode: DictationPostProcessMode {
        DictationPostProcessMode(rawValue: postProcessModeRaw) ?? .defaultValue
    }

    private func modeRow(_ mode: DictationPostProcessMode) -> some View {
        let selected = selectedMode == mode
        return Button { postProcessModeRaw = mode.rawValue } label: {
            HStack(spacing: 14) {
                Image(systemName: mode.icon).font(.system(size: 21)).foregroundStyle(.indigo)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mode.displayTitle).font(.system(size: 14, weight: .semibold))
                        if mode == .translateAndPolish {
                            Text("默认方式").font(.system(size: 9, weight: .medium)).foregroundStyle(.indigo)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.indigo.opacity(0.09), in: Capsule())
                        }
                    }
                    Text(mode.displayDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Color.indigo : Color.secondary.opacity(0.4))
            }
            .foregroundStyle(.primary).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.indigo.opacity(0.055) : Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.indigo.opacity(0.55) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选择" : "")
    }
}
