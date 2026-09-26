import AppKit
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let inVoiceOpenDiagnostics = Notification.Name("inVoiceOpenDiagnostics")
    static let inVoiceOpenHistory = Notification.Name("inVoiceOpenHistory")
    static let inVoiceSelectHistory = Notification.Name("inVoiceSelectHistory")
    static let inVoiceOpenAssistant = Notification.Name("inVoiceOpenAssistant")
    static let inVoiceSelectHome = Notification.Name("inVoiceSelectHome")
    static let inVoiceSelectSettings = Notification.Name("inVoiceSelectSettings")
}

private enum WorkspacePage { case home, history, settings }
private enum SettingsPage: String, CaseIterable {
    case general = "设置", dictation = "文字输出", shortcuts = "快捷键"
    case permissions = "权限与诊断", devices = "设备", prompts = "本地模型"
}

struct PreferencesView: View {
    @State private var page: WorkspacePage = .home
    @State private var settingsPage: SettingsPage = .general
    @StateObject private var status = ProductStatus.shared
    @State private var practiceText = ""
    @State private var recoveryTask: Task<Void, Never>?
    @State private var isRecovering = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.6)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 620)
        .task { await status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .inVoiceSelectHome)) { _ in page = .home }
        .onReceive(NotificationCenter.default.publisher(for: .inVoiceSelectHistory)) { _ in page = .history }
        .onReceive(NotificationCenter.default.publisher(for: .inVoiceSelectSettings)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: .inVoiceOpenDiagnostics)) { _ in openSettings(.permissions) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await status.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "inVoiceWorkspace" { recoveryTask?.cancel() }
        }
    }

    private func openSettings(_ destination: SettingsPage = .general) {
        settingsPage = destination
        page = .settings
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("inVoice").font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 18).padding(.top, 23).padding(.bottom, 27)
            navigationRow("听写", icon: "waveform", selected: page == .home) { page = .home }
                .help("听写 · ⌘1")
            navigationRow("剪贴板", icon: "doc.on.clipboard", selected: page == .history) { page = .history }
                .help("剪贴板 · ⌘2")
            navigationRow("助手", icon: "sparkles", selected: false, opensWindow: true) {
                NotificationCenter.default.post(name: .inVoiceOpenAssistant, object: nil)
            }.help("助手 · ⌘3")
            Spacer()
            navigationRow("设置", icon: "gearshape", selected: page == .settings) { openSettings() }
                .padding(.bottom, 16)
        }
        .frame(width: 174).background(.regularMaterial)
    }

    private func navigationRow(_ title: String, icon: String, selected: Bool,
                               opensWindow: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if opensWindow { Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 11).frame(height: 36)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 10)
            .accessibilityValue(selected ? "当前页面" : (opensWindow ? "在独立窗口打开" : ""))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if page == .settings && settingsPage != .general {
                Button { settingsPage = .general } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).help("返回设置").accessibilityLabel("返回设置")
            }
            Text(page == .home ? "听写" : (page == .history ? "剪贴板" : settingsPage.rawValue))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if page == .history {
                Button { ClipboardHistoryPanelController.shared.show() } label: {
                    Label("快捷面板", systemImage: "rectangle.on.rectangle")
                }.buttonStyle(.borderless).font(.system(size: 11))
                    .help("在其他应用使用 \(HotKeyPreference.load().displayString) 快速粘贴")
            } else if page == .home {
                Button { openSettings(.permissions) } label: {
                    HStack(spacing: 6) {
                        if status.isStarting && !status.canDictate { ProgressView().controlSize(.mini) }
                        else { Circle().fill(status.canDictate ? Color.green : .orange).frame(width: 6, height: 6) }
                        Text(status.canDictate ? "准备就绪" : (status.isStarting ? "正在准备…" : "完成设置"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("查看权限与运行状态")
            }
        }.padding(.horizontal, 24).frame(height: 46)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            HomeWorkspaceView(practiceText: $practiceText)
        case .history: HistoryWorkspaceView()
        case .settings:
            switch settingsPage {
            case .general: SettingsOverviewView(onOpen: { settingsPage = $0 })
            case .dictation: DictationSettingsView()
            case .shortcuts: HotKeySettingsView()
            case .devices: DeviceCenterView()
            case .prompts: PromptSettingsView()
            case .permissions:
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        PermissionsPanelView()
                        DisclosureGroup("服务与性能") {
                            runtimeCard.padding(.top, 12)
                        }.font(.system(size: 13, weight: .medium))
                    }.padding(28)
                }
            }
        }
    }

    private var runtimeCard: some View {
        SectionCard(title: "本机服务", subtitle: "异常时可尝试恢复，听写记录不受影响。") {
            ServiceStatusLine(title: "语音识别", availability: status.finalASR)
            ServiceStatusLine(title: "实时预览", availability: status.streamingASR)
            ServiceStatusLine(title: "文字整理与助手", availability: status.languageModel)
            Divider()
            HStack {
                Text("最近完成 \(status.summary.completedCount) 次听写").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let ms = status.summary.medianResponseMs {
                    Text(String(format: "典型等待 %.1f 秒", Double(ms) / 1_000)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(isRecovering ? "正在恢复…" : "恢复服务") {
                    isRecovering = true
                    recoveryTask = Task { await status.recover(); isRecovering = false }
                }.disabled(isRecovering)
                Button("重新检查") { Task { await status.refresh() } }.disabled(status.isRefreshing)
            }
        }
    }
}

private struct HomeWorkspaceView: View {
    @Binding var practiceText: String
    @FocusState private var practiceFocused: Bool
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var activationKey = ActivationKeyPreference.load().displayString
    @AppStorage(DictationPostProcessMode.defaultsKey) private var mode = DictationPostProcessMode.defaultValue.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor).padding(.bottom, 8)
                    Text("把想法，说出来。").font(.system(size: 30, weight: .semibold))
                    Text("按住 \(activationKey) 说话，松开即输入。")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $practiceText).font(.system(size: 17)).lineSpacing(6)
                            .scrollContentBackground(.hidden).padding(16).focused($practiceFocused)
                            .accessibilityLabel("听写体验区")
                        if practiceText.isEmpty {
                            Text(practiceFocused ? "按住 \(activationKey)，试着说一句…" : "点这里，试着说一句…")
                                .font(.system(size: 17)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 21).padding(.top, 24).allowsHitTesting(false)
                        }
                    }.frame(height: 190)
                    Divider().padding(.horizontal, 18)
                    HStack(spacing: 9) {
                        Text(activationKey).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        Text("按住说话").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if !practiceText.isEmpty {
                            Button { copyPractice() } label: { Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "doc.on.doc") }
                                .controlSize(.small).help("复制体验区的全部内容")
                        }
                        Menu {
                            Picker("文字输出", selection: $mode) {
                                ForEach(DictationPostProcessMode.allCases, id: \.rawValue) { Text($0.displayTitle).tag($0.rawValue) }
                            }
                        } label: {
                            Text((DictationPostProcessMode(rawValue: mode) ?? .defaultValue).displayTitle)
                        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                            .help("更改下一次听写的输出方式")
                    }.padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(practiceFocused ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "lock").font(.system(size: 11))
                    Text("在这台 Mac 上处理。\n邮件、聊天和文档里，也同样好用。")
                        .font(.system(size: 12)).lineSpacing(5)
                }.foregroundStyle(.secondary)
            }.frame(maxWidth: 590, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 42)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: practiceText) { _ in didCopy = false }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            activationKey = ActivationKeyPreference.load().displayString
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    private func copyPractice() {
        ClipboardObserver.shared.markInternalWrite()
        NSPasteboard.general.clearContents()
        didCopy = NSPasteboard.general.setString(practiceText, forType: .string)
        copyResetTask?.cancel()
        copyResetTask = Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            didCopy = false
        }
    }
}

private struct ServiceStatusLine: View {
    let title: String
    let availability: ProductStatus.Availability
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Label(availability.title, systemImage: availability == .ready ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 12)).foregroundStyle(availability == .ready ? Color.green : .orange)
        }.padding(.vertical, 3)
    }
}

private struct SettingsOverviewView: View {
    let onOpen: (SettingsPage) -> Void
    @AppStorage(ClipboardCapturePolicy.enabledKey) private var captureClipboard = true
    @AppStorage(DictationPostProcessMode.defaultsKey) private var mode = DictationPostProcessMode.defaultValue.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionCard(title: "日常使用", subtitle: "按你的习惯，随时调整。") {
                    settingsLink(.dictation, symbol: "text.bubble", detail: (DictationPostProcessMode(rawValue: mode) ?? .defaultValue).displayTitle)
                    Divider()
                    settingsLink(.shortcuts, symbol: "keyboard", detail: ActivationKeyPreference.load().displayString)
                    Divider()
                    Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                        .toggleStyle(.switch).controlSize(.small)
                    if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.orange) }
                }
                SectionCard(title: "隐私", subtitle: "语音和文字在本机处理。") {
                    Toggle("保存剪贴板历史", isOn: $captureClipboard).toggleStyle(.switch).controlSize(.small)
                    Text("暂停后保留已有记录；主动听写仍会保存。跳过应用标记为敏感或临时的内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    settingsLink(.permissions, symbol: "hand.raised", detail: "")
                }
                SectionCard(title: "更多", subtitle: "连接设备或调整本地模型。") {
                    settingsLink(.devices, symbol: "hifispeaker", detail: "")
                    Divider()
                    settingsLink(.prompts, symbol: "cpu", detail: "")
                }
                HStack {
                    Text("inVoice \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    Spacer()
                    Text("关闭窗口后，仍可从菜单栏使用。")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: 640).padding(28).frame(maxWidth: .infinity)
        }
    }

    private func settingsLink(_ destination: SettingsPage, symbol: String, detail: String) -> some View {
        Button { onOpen(destination) } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(destination.rawValue).foregroundStyle(.primary)
                Spacer()
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.font(.system(size: 13)).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许 inVoice。" : nil
        } catch { loginMessage = "未能更新登录项，请稍后重试。" }
        launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }
}
