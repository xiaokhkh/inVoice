import AppKit
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let inVoiceOpenDiagnostics = Notification.Name("inVoiceOpenDiagnostics")
    static let inVoiceOpenAssistant = Notification.Name("inVoiceOpenAssistant")
}

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case home, history, dictation, shortcuts, permissions, devices, prompts, general
    var id: Self { self }
    var title: String {
        switch self {
        case .home: return "概览"
        case .history: return "历史记录"
        case .dictation: return "语音输入"
        case .shortcuts: return "快捷键"
        case .permissions: return "权限与诊断"
        case .devices: return "设备"
        case .prompts: return "本地 AI"
        case .general: return "通用与隐私"
        }
    }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .dictation: return "waveform"
        case .shortcuts: return "keyboard"
        case .permissions: return "checkmark.shield"
        case .devices: return "hifispeaker"
        case .prompts: return "sparkles"
        case .general: return "slider.horizontal.3"
        }
    }
}

struct PreferencesView: View {
    @State private var page: WorkspacePage = .home
    @StateObject private var status = ProductStatus.shared
    @State private var recoveryTask: Task<Void, Never>?
    @State private var isRecovering = false
    @State private var practiceText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(page.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Label("在这台 Mac 上处理", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).frame(height: 48)
                Divider().opacity(0.5)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.indigo)
        .frame(minWidth: 860, minHeight: 620)
        .task { await status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .inVoiceOpenDiagnostics)) { _ in
            page = .permissions
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await status.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "inVoiceWorkspace" {
                recoveryTask?.cancel()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 35, height: 35)
                VStack(alignment: .leading, spacing: 2) {
                    Text("inVoice").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("把想法，说成文字").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 30)

            navRow(.home)
            navRow(.history)
            Text("偏好设置").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 24).padding(.top, 26).padding(.bottom, 8)
            ForEach(Array(WorkspacePage.allCases.dropFirst(2))) { navRow($0) }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(status.canDictate ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(status.canDictate ? status.phase : (status.isStarting ? "服务启动中…" : "查看运行状态")).font(.system(size: 11, weight: .medium))
                }
                Text("按住 \(ActivationKeyPreference.load().displayString) · 自然说话")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .padding(14)
        }
        .frame(width: 190)
        .background(.regularMaterial)
    }

    private func navRow(_ item: WorkspacePage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 14)).frame(width: 20)
                Text(item.title).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(page == item ? Color.indigo : Color.primary.opacity(0.75))
            .padding(.horizontal, 12).frame(height: 38)
            .background(page == item ? Color.indigo.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2)
        .accessibilityValue(page == item ? "当前页面" : "")
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            HomeWorkspaceView(status: status, practiceText: $practiceText,
                              onSettings: { page = .dictation }, onHistory: { page = .history },
                              onSetup: { page = .permissions })
        case .history: HistoryWorkspaceView()
        case .dictation: DictationSettingsView()
        case .shortcuts: HotKeySettingsView()
        case .permissions:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PreferencesHeader(title: "每一步，都有状态", subtitle: "授权、服务和模型的真实状态。遇到问题时，从这里恢复。")
                    runtimeCard
                    PermissionsPanelView()
                }.padding(28)
            }
        case .devices: DeviceCenterView()
        case .prompts: PromptSettingsView()
        case .general: GeneralWorkspaceView()
        }
    }

    private var runtimeCard: some View {
        SectionCard(title: "本地服务", subtitle: "实时检查运行情况；模型文件存在并不代表服务已就绪。") {
            ServiceStatusLine(title: "语音识别", detail: "决定最终文字是否可用", availability: status.finalASR)
            ServiceStatusLine(title: "实时预览", detail: "边说边显示文字", availability: status.streamingASR)
            ServiceStatusLine(title: "文字整理与助手", detail: "不可用时，听写仍会保留原文", availability: status.languageModel)
            Divider()
            HStack {
                Button(isRecovering ? "正在恢复…" : "恢复语音服务") {
                    isRecovering = true
                    recoveryTask = Task {
                        await status.recover()
                        isRecovering = false
                    }
                }.disabled(isRecovering)
                Button("重新检查") { Task { await status.refresh() } }.disabled(status.isRefreshing)
                Spacer()
                if let checkedAt = status.checkedAt {
                    Text(checkedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct HomeWorkspaceView: View {
    @ObservedObject var status: ProductStatus
    @Binding var practiceText: String
    let onSettings: () -> Void
    let onHistory: () -> Void
    let onSetup: () -> Void
    @FocusState private var practiceFocused: Bool
    @State private var didCopy = false
    @AppStorage(DictationPostProcessMode.defaultsKey) private var mode = DictationPostProcessMode.defaultValue.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("让表达，自然发生。").font(.system(size: 29, weight: .semibold))
                        Text("在任何输入框，把想法变成文字。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onSetup) {
                        Label(status.canDictate ? "可以开始听写" : (status.isStarting ? "服务启动中…" : "需要完成设置"),
                              systemImage: status.canDictate ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(status.canDictate ? Color.green : Color.orange)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background((status.canDictate ? Color.green : Color.orange).opacity(0.08), in: Capsule())
                    }.buttonStyle(.plain)
                }
                hero
                HStack(spacing: 14) {
                    metric(value: "\(status.summary.completedCount)", title: "最近完成的听写", icon: "checkmark.bubble")
                    metric(value: responseTime, title: "松开后的典型等待", icon: "timer")
                    metric(value: "本机", title: "音频与文字处理", icon: "lock.shield")
                }
                practice
                HStack(spacing: 14) {
                    quickAction(title: "历史记录", detail: "找回听写，复用剪贴板", icon: "clock.arrow.circlepath", action: onHistory)
                    quickAction(title: "本地助手", detail: "翻译、改写，或聊聊想法", icon: "sparkles") {
                        NotificationCenter.default.post(name: .inVoiceOpenAssistant, object: nil)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("切换到其他应用时，结果会保留在剪贴板，供你手动粘贴。")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28)
        }
    }

    private var hero: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 7) {
                    Text("你的语音工作流").font(.system(size: 11, weight: .medium))
                    Spacer()
                }.foregroundStyle(.indigo)
                HStack(alignment: .center, spacing: 13) {
                    Text(ActivationKeyPreference.load().displayString)
                        .font(.system(size: 25, weight: .medium, design: .rounded))
                        .padding(.horizontal, 15).frame(height: 53)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.indigo.opacity(0.13)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按住说话，松开即输入").font(.system(size: 19, weight: .semibold))
                        Text("邮件、聊天、文档、代码编辑器，随处可用。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("输出方式").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("输出方式", selection: $mode) {
                        ForEach(DictationPostProcessMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayTitle).tag(mode.rawValue)
                        }
                    }.labelsHidden().frame(width: 150)
                    Spacer()
                    Button("调整偏好", action: onSettings).buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
        .padding(24)
        .background(LinearGradient(colors: [Color.indigo.opacity(0.10), Color.purple.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.indigo.opacity(0.08)))
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在这里，试着说一句").font(.system(size: 15, weight: .semibold))
                    Text("点击下方，按住 \(ActivationKeyPreference.load().displayString) 说话，松开后文字会出现在这里。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if !practiceText.isEmpty {
                    Button(didCopy ? "已复制" : "复制") {
                        ClipboardObserver.shared.markInternalWrite()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(practiceText, forType: .string)
                        didCopy = true
                    }.controlSize(.small)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(10).focused($practiceFocused)
                    .accessibilityLabel("语音练习区")
                if practiceText.isEmpty && !practiceFocused {
                    Text("例如：帮我记一下，周五前完成产品体验的优化。")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(15).allowsHitTesting(false)
                }
            }
            .frame(height: 88)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(practiceFocused ? Color.indigo.opacity(0.65) : Color.primary.opacity(0.10), lineWidth: 1))
            Text("练习内容仅保留在当前窗口；成功的听写也可在历史记录中找回。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onChange(of: practiceText) { _ in didCopy = false }
    }

    private var responseTime: String {
        guard let ms = status.summary.medianResponseMs else { return "—" }
        return String(format: "%.1f 秒", Double(ms) / 1_000)
    }

    private func metric(value: String, title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .help("基于最近 14 天日志末尾最多 512 KB 的已完成会话；没有记录时显示 —。")
    }

    private func quickAction(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ServiceStatusLine: View {
    let title: String
    let detail: String
    let availability: ProductStatus.Availability
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(availability.title, systemImage: availability == .ready ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 12)).foregroundStyle(availability == .ready ? Color.green : Color.orange)
        }.padding(.vertical, 3)
    }
}

private struct HistoryWorkspaceView: View {
    @StateObject private var model = ClipboardHistoryViewModel()
    @State private var query = ""
    @State private var voiceOnly = true
    @State private var copiedID: UUID?
    private var items: [ClipboardItem] { model.items.filter { !voiceOnly || $0.source == .voiceops } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PreferencesHeader(title: "好表达，随时找回", subtitle: "最近 200 条记录保存在本机。固定常用内容，复制后继续使用。")
            HStack {
                TextField("搜索文字…", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索历史记录")
                Picker("记录类型", selection: $voiceOnly) {
                    Text("语音输入").tag(true)
                    Text("全部剪贴板").tag(false)
                }.pickerStyle(.segmented).frame(width: 210)
            }
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: query.isEmpty ? "text.bubble" : "magnifyingglass")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.indigo.opacity(0.6))
                    Text(query.isEmpty ? "下一次表达，从这里留下" : "没有找到匹配内容")
                        .font(.system(size: 16, weight: .semibold))
                    Text(query.isEmpty ? "完成一次听写后，结果会自动出现在这里。" : "试试更短的关键词，或切换到全部剪贴板。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if !query.isEmpty { Button("清除搜索") { query = "" } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            historyRow(item)
                        }
                    }.padding(.bottom, 8)
                }
            }
            Label("只有你主动复制或完成听写时才会保存记录。可在「通用与隐私」暂停剪贴板收集。", systemImage: "lock")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(28)
        .onChange(of: query) { model.setQuery($0) }
    }

    private func historyRow(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = item.contentText {
                Text(text).font(.system(size: 13)).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("图片 · 复制后可粘贴到其他应用", systemImage: "photo").font(.system(size: 13))
            }
            HStack(spacing: 9) {
                Image(systemName: item.source == .voiceops ? "waveform" : "doc.on.clipboard")
                Text(Date(timeIntervalSince1970: Double(item.timestamp) / 1_000), style: .relative)
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.indigo) }
                Spacer()
                Button(item.pinned ? "取消固定" : "固定") { model.togglePinned(item) }
                Button(copiedID == item.id ? "已复制" : "复制") { model.copyItem(item); copiedID = item.id }
            }.font(.system(size: 11)).foregroundStyle(.secondary).controlSize(.small)
        }
        .padding(16).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

private struct GeneralWorkspaceView: View {
    @AppStorage(ClipboardCapturePolicy.enabledKey) private var captureClipboard = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PreferencesHeader(title: "融入你的 Mac", subtitle: "启动方式与数据边界，由你掌控。设置即时生效。")
                SectionCard(title: "日常使用", subtitle: "关闭主窗口后，inVoice 仍在菜单栏待命。") {
                    Toggle("登录 Mac 时启动 inVoice", isOn: Binding(
                        get: { launchAtLogin },
                        set: { value in
                            do {
                                if value { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                loginMessage = SMAppService.mainApp.status == .requiresApproval
                                    ? "请在系统设置的「登录项」中允许 inVoice。" : nil
                            } catch {
                                loginMessage = "未能更新登录项：\(error.localizedDescription)"
                            }
                            let status = SMAppService.mainApp.status
                            launchAtLogin = status == .enabled || status == .requiresApproval
                        }
                    ))
                    if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.orange) }
                    Text("打开主窗口：⌘⌥P；在菜单栏选择「退出 inVoice」可完全退出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionCard(title: "剪贴板隐私", subtitle: "记录保存在这台 Mac，不同步到云端。") {
                    Toggle("保存系统剪贴板历史", isOn: $captureClipboard)
                    Text("关闭后停止收集新的系统剪贴板内容，已有记录和主动听写的结果仍可使用。标记为密码、临时或隐藏的剪贴板内容不会收集。")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("复制图片网址时，只保存网址，不会在后台访问链接。", systemImage: "network.badge.shield.half.filled")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionCard(title: "关于 inVoice", subtitle: "本地优先的 Mac 语音工作台") {
                    HStack {
                        Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                        Spacer()
                        Button("在 Finder 中显示应用") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }
                    Text("语音识别、文字整理与助手在本机运行。麦克风只在你发起录音时使用；性能日志不包含音频和正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
