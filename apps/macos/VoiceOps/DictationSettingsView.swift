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
                PreferencesHeader(title: "文字输出", subtitle: "选择一种方式，下一次听写立即生效。")
                Picker("文字输出", selection: $postProcessModeRaw) {
                    ForEach(DictationPostProcessMode.allCases, id: \.rawValue) { Text($0.displayTitle).tag($0.rawValue) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(selectedMode.displayDetail).font(.system(size: 13)).foregroundStyle(.secondary)
                SectionCard(title: "试想你说了这句话", subtitle: "嗯，那个周五之前把这个方案发给我。") {
                    Divider().padding(.vertical, 4)
                    Text(selectedMode.example).font(.system(size: 17, weight: .medium)).lineSpacing(5)
                        .textSelection(.enabled).padding(.vertical, 8)
                }
                if selectedMode != .direct && status.languageModel == .unavailable {
                    Label("文字整理暂不可用，听写会先保留原文。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.orange)
                    Button("检查本地服务") { NotificationCenter.default.post(name: .inVoiceOpenDiagnostics, object: nil) }
                }
                DisclosureGroup("识别与速度") {
                    VStack(alignment: .leading, spacing: 14) {
                        if streamingFinalsApproved {
                            Picker("识别模式", selection: $asrModeRaw) {
                                Text("准确优先").tag(DictationASRMode.accurate.rawValue)
                                Text("速度优先").tag(DictationASRMode.fast.rawValue)
                                Text("自动平衡").tag(DictationASRMode.adaptive.rawValue)
                            }
                        } else { Label("准确优先", systemImage: "checkmark") }
                        Text("原样转写的等待更短。首次使用时，模型加载可能需要一些时间。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                }.font(.system(size: 13))
            }.frame(maxWidth: 620).padding(28).frame(maxWidth: .infinity)
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
}
