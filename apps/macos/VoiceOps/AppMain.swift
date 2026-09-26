import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct InVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { PreferencesView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { appDelegate.openSettings() }.keyboardShortcut(",")
                }
                CommandMenu("前往") {
                    Button("听写") { appDelegate.openDictationWorkspace() }.keyboardShortcut("1")
                    Button("剪贴板") { appDelegate.openClipboardWorkspace() }.keyboardShortcut("2")
                    Button("助手") { NotificationCenter.default.post(name: .inVoiceOpenAssistant, object: nil) }.keyboardShortcut("3")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let didShowWelcomeKey = "didShowInVoiceWelcome"
    private let statusIdleTitle = "inVoice"
    private var statusItem: NSStatusItem?
    private var dictationMenuItem: NSMenuItem?
    private var setupSummaryMenuItem: NSMenuItem?
    private var deviceInputMenuItem: NSMenuItem?
    private var deviceAudioMenuItem: NSMenuItem?
    private var panel: OverlayPanel?
    private var previewPanel: PreviewPanel?
    private let previewModel = PreviewModel()
    private var previewDismissWorkItem: DispatchWorkItem?
    private var previewMergeInFlight = false
    private var clipboardHotKeyPreference = HotKeyPreference.defaultValue
    private var activationPreference = ActivationKeyPreference.defaultValue
    private var translateHotKeyPreference = TranslateHotKeyPreference.defaultValue
    private var hotKeyDefaultsObserver: Any?
    private var settingsWindowController: NSWindowController?
    private var preferencesHotKey: HotKeyService?
    private let fnMonitor = FnKeyMonitor()
    private let fnSession = FnSessionController()
    private let wirelessVoiceProvider = WirelessVoiceProvider.shared
    private let deviceManager = DeviceManager.shared
    private let clipboardObserver = ClipboardObserver.shared
    private let clipboardPanel = ClipboardHistoryPanelController.shared
    private let translatePanel = SelectionTranslationPanelController.shared
    private let sidecarLauncher = SidecarLauncher.shared
    private let selectionCapture = SelectionCaptureService.shared
    private let inputInjector = InputInjector()
    private var fnHoldActive = false
    private var activeVoiceProvider: VoiceInputProvider?
    private var wirelessCaptureReady = false
    private var wirelessReleasePending = false
    private var pendingWirelessAudio: [WirelessVoiceAudioPacket] = []
    private var cancellables = Set<AnyCancellable>()

    private let pipeline = PipelineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        TranslationPromptDefaults.migrateIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupOverlay()
        setupPreviewPanel()
        setupShortcuts()
        setupPreferencesHotKey()
        setupFnMonitor()
        setupWirelessVoiceProvider()
        bindPipeline()
        NotificationCenter.default.publisher(for: .inVoiceOpenAssistant)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.translatePanel.show(selection: .empty(.noSelection)) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .inVoiceOpenHistory)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.openClipboardWorkspace()
            }
            .store(in: &cancellables)
        Task { await ProductStatus.shared.waitForStartup() }
        clipboardObserver.start()
        sidecarLauncher.startAll()

        let defaults = UserDefaults.standard
        let isFirstRun = !defaults.bool(forKey: didShowWelcomeKey)
        if isFirstRun {
            defaults.set(true, forKey: didShowWelcomeKey)
        }

        #if DEBUG
        let isTranslationPanelPreview =
            ProcessInfo.processInfo.environment["INVOICE_TRANSLATION_PANEL_PREVIEW"] == "1"
                || defaults.bool(forKey: "INVOICE_TRANSLATION_PANEL_PREVIEW")
        let isAudioInputPreview =
            ProcessInfo.processInfo.environment["INVOICE_AUDIO_INPUT_PREVIEW"] == "1"
                || defaults.bool(forKey: "INVOICE_AUDIO_INPUT_PREVIEW")
        #else
        let isTranslationPanelPreview = false
        let isAudioInputPreview = false
        #endif

        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !isTranslationPanelPreview && !isAudioInputPreview && (isFirstRun || !launchedAtLogin
            || ProcessInfo.processInfo.environment["INVOICE_OPEN_SETTINGS"] == "1"
            || ProcessInfo.processInfo.environment["VOICEOPS_OPEN_PREFERENCES"] == "1") {
            DispatchQueue.main.async { [weak self] in
                self?.openPreferences()
            }
        }

        #if DEBUG
        if isAudioInputPreview {
            let previewState = defaults.string(forKey: "INVOICE_AUDIO_INPUT_PREVIEW_STATE") ?? "live"
            previewPanel?.resetToListening()
            switch previewState {
            case "compact":
                previewModel.text = ""
                previewModel.state = .recording
            case "processing":
                previewModel.text = "哈喽，哈喽"
                previewModel.state = .processing
            case "result":
                previewModel.text = "哈喽哈喽"
                previewModel.state = .result
            default:
                previewModel.text = "哈喽，哈喽"
                previewModel.state = .recording
            }
            previewPanel?.update(text: previewModel.text, state: previewModel.state, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.previewPanel?.show()
            }
        } else if isTranslationPanelPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.translatePanel.showPreview()
            }
        }
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = statusIdleTitle
        item.button?.toolTip = "inVoice · 本地语音工作台"

        let menu = NSMenu()
        menu.delegate = self

        let dictationItem = NSMenuItem(title: "开始听写…", action: #selector(toggleDictation), keyEquivalent: "")
        let clipboardItem = NSMenuItem(title: "剪贴板…", action: #selector(showClipboardHistory), keyEquivalent: "")
        let translateItem = NSMenuItem(title: "助手…", action: #selector(translateSelection), keyEquivalent: "")
        let setupItem = NSMenuItem(title: setupSummary, action: nil, keyEquivalent: "")
        let inputItem = NSMenuItem(title: deviceManager.inputSourceSummary, action: nil, keyEquivalent: "")
        let audioItem = NSMenuItem(title: deviceManager.audioSummary, action: nil, keyEquivalent: "")
        let preferencesItem = NSMenuItem(title: "打开 inVoice", action: #selector(openPreferences), keyEquivalent: "")
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        let deviceItem = NSMenuItem(title: "输入设备", action: nil, keyEquivalent: "")
        deviceItem.submenu = NSMenu()
        deviceItem.submenu?.addItem(inputItem)
        deviceItem.submenu?.addItem(audioItem)
        let quitItem = NSMenuItem(title: "退出 inVoice", action: #selector(quitApp), keyEquivalent: "q")

        dictationItem.target = self
        clipboardItem.target = self
        translateItem.target = self
        preferencesItem.target = self
        settingsItem.target = self
        quitItem.target = self
        setupItem.isEnabled = false
        inputItem.isEnabled = false
        audioItem.isEnabled = false

        menu.addItem(dictationItem)
        menu.addItem(clipboardItem)
        menu.addItem(translateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(setupItem)
        menu.addItem(deviceItem)
        menu.addItem(preferencesItem)
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        dictationMenuItem = dictationItem
        setupSummaryMenuItem = setupItem
        deviceInputMenuItem = inputItem
        deviceAudioMenuItem = audioItem
    }

    private func setupOverlay() {
        let view = OverlayView(onOpenSettings: { [weak self] in
            self?.openPreferences()
        }).environmentObject(pipeline)
        panel = OverlayPanel(rootView: view)
        panel?.onSubmit = { [weak self] in
            self?.pipeline.insertToFocusedApp()
        }
        panel?.onCancel = { [weak self] in
            self?.pipeline.cancel()
        }
    }

    private func setupPreviewPanel() {
        let view = PreviewView(
            model: previewModel,
            onDismiss: { [weak self] in
                self?.dismissPreviewResult()
            },
            onCopy: { [weak self] text in
                self?.copyPreviewText(text)
            },
            onOpenSettings: { [weak self] in
                self?.dismissPreviewResult()
                self?.openPreferences()
                NotificationCenter.default.post(name: .inVoiceOpenDiagnostics, object: nil)
            }
        )
        previewPanel = PreviewPanel(rootView: view)
    }

    private func setupShortcuts() {
        activationPreference = ActivationKeyPreference.load()
        fnMonitor.updateActivationKey(keyCode: activationPreference.keyCode, modifiers: activationPreference.modifiers)
        clipboardHotKeyPreference = HotKeyPreference.load()
        fnMonitor.updateClipboardShortcut(keyCode: clipboardHotKeyPreference.keyCode, modifiers: clipboardHotKeyPreference.modifiers)
        translateHotKeyPreference = TranslateHotKeyPreference.load()
        fnMonitor.updateTranslateShortcut(
            keyCode: translateHotKeyPreference.keyCode,
            modifiers: translateHotKeyPreference.modifiers
        )
        hotKeyDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadActivationKeyIfNeeded()
                self?.reloadClipboardHotKeyIfNeeded()
                self?.reloadTranslateHotKeyIfNeeded()
            }
        }
    }

    private func setupPreferencesHotKey() {
        do {
            preferencesHotKey = try HotKeyService(
                keyCode: UInt32(kVK_ANSI_P),
                modifiers: UInt32(cmdKey | optionKey)
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.openSettings()
                }
            }
        } catch {
            print("[hotkey] preferences_register_failed error=\(error)")
        }
    }

    private func reloadClipboardHotKeyIfNeeded() {
        let latest = HotKeyPreference.load()
        guard latest != clipboardHotKeyPreference else { return }
        clipboardHotKeyPreference = latest
        fnMonitor.updateClipboardShortcut(keyCode: latest.keyCode, modifiers: latest.modifiers)
    }

    private func reloadActivationKeyIfNeeded() {
        let latest = ActivationKeyPreference.load()
        guard latest != activationPreference else { return }
        activationPreference = latest
        fnMonitor.updateActivationKey(keyCode: latest.keyCode, modifiers: latest.modifiers)
    }

    private func reloadTranslateHotKeyIfNeeded() {
        let latest = TranslateHotKeyPreference.load()
        guard latest != translateHotKeyPreference else { return }
        translateHotKeyPreference = latest
        fnMonitor.updateTranslateShortcut(keyCode: latest.keyCode, modifiers: latest.modifiers)
    }

    private func setupFnMonitor() {
        fnMonitor.onFnDown = { [weak self] in
            self?.handleFnDown()
        }
        fnMonitor.onFnUp = { [weak self] in
            self?.handleFnUp()
        }
        fnMonitor.onClipboardToggle = { [weak self] in
            self?.clipboardPanel.toggle()
        }
        fnMonitor.onTranslateSelection = { [weak self] in
            self?.handleTranslateSelection()
        }
        fnSession.onIndicatorChange = { [weak self] state in
            self?.updateStatusIndicator(state)
        }
        fnSession.onPreviewText = { [weak self] text in
            guard let self else { return }
            self.previewModel.text = text
            self.previewPanel?.update(text: text, state: .recording)
        }
        fnSession.onFinalText = { [weak self] text in
            guard let self else { return }
            self.previewDismissWorkItem?.cancel()
            self.previewModel.text = text
            self.previewModel.state = .processing
            self.previewPanel?.update(text: text, state: .processing)
            self.previewPanel?.show()
        }
        fnSession.onDeliveryResult = { [weak self] status in
            guard let self else { return }
            if status.didPostPaste {
                self.mergePreviewIntoTarget()
            } else {
                self.previewMergeInFlight = false
                self.previewModel.state = .result
                self.previewPanel?.update(text: self.previewModel.text, state: .result)
                self.previewPanel?.show()
                self.schedulePreviewResultDismissal()
            }
        }
        fnSession.onFailure = { [weak self] message in
            guard let self else { return }
            self.previewMergeInFlight = false
            self.previewModel.state = .failure
            self.previewModel.text = self.compactPreviewFailure(message)
            self.previewPanel?.update(text: self.previewModel.text, state: .failure)
            self.setStatusTitle("inVoice !")
            self.previewPanel?.show()
            self.schedulePreviewResultDismissal()
        }
        if Permissions.hasInputMonitoring() {
            fnMonitor.start()
        }
    }

    private func handleFnDown() {
        beginVoiceHold(provider: .usbAudio)
    }

    private func handleFnUp() {
        endVoiceHold(provider: .usbAudio)
    }

    private func setupWirelessVoiceProvider() {
        wirelessVoiceProvider.onPTTChanged = { [weak self] pressed in
            guard let self else { return }
            if pressed {
                self.beginVoiceHold(provider: .wirelessStopWatch)
            } else {
                self.endVoiceHold(provider: .wirelessStopWatch)
            }
        }
        wirelessVoiceProvider.onAudioPacket = { [weak self] packet in
            self?.handleWirelessAudio(packet)
        }
        wirelessVoiceProvider.onControl = { [weak self] control in
            switch control {
            case "clipboard":
                self?.clipboardPanel.toggle()
            case "return":
                _ = self?.inputInjector.pressReturn()
            default:
                break
            }
        }
        wirelessVoiceProvider.onConnectionState = { [weak self] state in
            NSLog("VoiceOps: wireless provider state=%@", String(describing: state))
            self?.deviceManager.handleConnectionState(state)
        }
        wirelessVoiceProvider.onAudioStateChanged = { [weak self] state in
            self?.deviceManager.handleAudioState(state)
        }
        deviceManager.start()
    }

    private func beginVoiceHold(provider: VoiceInputProvider) {
        guard activeVoiceProvider == nil else { return }
        activeVoiceProvider = provider
        fnHoldActive = true
        if provider == .wirelessStopWatch {
            wirelessCaptureReady = false
            wirelessReleasePending = false
            pendingWirelessAudio.removeAll(keepingCapacity: true)
        }
        previewMergeInFlight = false
        previewDismissWorkItem?.cancel()
        clipboardPanel.hide()
        panel?.hide()
        previewModel.text = ""
        previewModel.state = .recording
        previewPanel?.resetToListening()
        previewPanel?.show()
        Task { [weak self] in
            guard let self else { return }
            let started = await self.fnSession.startSession(provider: provider)
            guard self.activeVoiceProvider == provider else { return }
            guard started else {
                self.resetVoiceHold(provider: provider)
                return
            }
            if provider == .wirelessStopWatch {
                self.wirelessCaptureReady = true
                let buffered = self.pendingWirelessAudio
                self.pendingWirelessAudio.removeAll(keepingCapacity: true)
                for packet in buffered {
                    self.fnSession.appendWirelessAudio(packet)
                }
                if self.wirelessReleasePending {
                    self.finishVoiceHold(provider: provider)
                }
            }
        }
    }

    private func endVoiceHold(provider: VoiceInputProvider) {
        guard activeVoiceProvider == provider else { return }
        if provider == .wirelessStopWatch, !wirelessCaptureReady {
            wirelessReleasePending = true
            return
        }
        finishVoiceHold(provider: provider)
    }

    private func finishVoiceHold(provider: VoiceInputProvider) {
        guard activeVoiceProvider == provider else { return }
        activeVoiceProvider = nil
        fnHoldActive = false
        wirelessCaptureReady = false
        wirelessReleasePending = false
        pendingWirelessAudio.removeAll(keepingCapacity: true)
        fnSession.endSession()
    }

    private func resetVoiceHold(provider: VoiceInputProvider) {
        guard activeVoiceProvider == provider else { return }
        activeVoiceProvider = nil
        fnHoldActive = false
        wirelessCaptureReady = false
        wirelessReleasePending = false
        pendingWirelessAudio.removeAll(keepingCapacity: true)
        if previewModel.state != .failure {
            previewModel.state = .idle
            previewPanel?.hide()
        }
    }

    private func handleWirelessAudio(_ packet: WirelessVoiceAudioPacket) {
        guard activeVoiceProvider == .wirelessStopWatch else { return }
        if wirelessCaptureReady {
            fnSession.appendWirelessAudio(packet)
            return
        }
        // Selection capture happens before audio capture starts. Keep up to ten
        // seconds of 20 ms frames so a quick wireless press is still complete.
        if pendingWirelessAudio.count >= 500 {
            pendingWirelessAudio.removeFirst()
        }
        pendingWirelessAudio.append(packet)
    }

    private func handleTranslateSelection() {
        clipboardPanel.hide()
        panel?.hide()
        guard Permissions.hasAccessibility() else {
            openPreferences()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let selection = await selectionCapture.captureSelection()
            await MainActor.run {
                self.translatePanel.show(selection: selection)
            }
        }
    }

    private func updateStatusIndicator(_ state: FnSessionController.IndicatorState) {
        switch state {
        case .idle: ProductStatus.shared.phase = "准备就绪"
        case .recording: ProductStatus.shared.phase = "正在聆听…"
        case .processing: ProductStatus.shared.phase = "正在整理…"
        }
        switch state {
        case .idle:
            setStatusTitle(statusIdleTitle)
            if previewMergeInFlight {
                break
            } else if (previewModel.state == .result || previewModel.state == .failure), !previewModel.text.isEmpty {
                schedulePreviewResultDismissal()
            } else if !fnHoldActive {
                previewModel.state = .idle
                previewPanel?.hide()
            }
        case .recording:
            previewModel.state = .recording
            previewPanel?.update(text: previewModel.text, state: .recording)
            setStatusTitle("inVoice •")
        case .processing:
            previewModel.state = .processing
            previewPanel?.update(text: previewModel.text, state: .processing)
            setStatusTitle("inVoice …")
        }
    }

    private func schedulePreviewResultDismissal() {
        previewDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissPreviewResult()
        }
        previewDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (previewModel.state == .failure ? 12 : 8), execute: workItem)
    }

    private func dismissPreviewResult() {
        previewDismissWorkItem?.cancel()
        previewDismissWorkItem = nil
        previewMergeInFlight = false
        previewModel.state = .idle
        previewModel.text = ""
        previewPanel?.hide()
        previewPanel?.resetToListening()
    }

    private func copyPreviewText(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        schedulePreviewResultDismissal()
    }

    private func mergePreviewIntoTarget() {
        previewDismissWorkItem?.cancel()
        previewDismissWorkItem = nil
        previewMergeInFlight = true
        previewPanel?.mergeIntoTarget { [weak self] in
            guard let self else { return }
            self.previewMergeInFlight = false
            self.previewModel.state = .idle
            self.previewModel.text = ""
            self.previewPanel?.resetToListening()
        }
    }

    private func compactPreviewFailure(_ message: String) -> String {
        if message.contains("Streaming fallback") {
            return "语音服务暂不可用，点击右侧检查"
        }
        if message.contains("GLM-ASR") {
            return "语音服务暂不可用，点击右侧检查"
        }
        return message
    }

    private func bindPipeline() {
        pipeline.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if self?.fnHoldActive == true {
                    self?.panel?.hide()
                    return
                }
                self?.updatePipelineStatus(state)
                switch state {
                case .idle:
                    self?.panel?.hide()
                default:
                    self?.panel?.show()
                }
            }
            .store(in: &cancellables)
    }

    private func updatePipelineStatus(_ state: PipelineController.State) {
        switch state {
        case .idle:
            setStatusTitle(statusIdleTitle)
            dictationMenuItem?.title = "开始听写…"
            dictationMenuItem?.isEnabled = true
        case .recording:
            setStatusTitle("inVoice •")
            dictationMenuItem?.title = "结束并整理"
            dictationMenuItem?.isEnabled = true
        case .transcribing, .generating:
            setStatusTitle("inVoice …")
            dictationMenuItem?.title = "处理中…"
            dictationMenuItem?.isEnabled = false
        case .ready:
            setStatusTitle("inVoice ✓")
            dictationMenuItem?.title = "开始新的听写…"
            dictationMenuItem?.isEnabled = true
        case .error:
            setStatusTitle("inVoice !")
            dictationMenuItem?.title = "重新听写…"
            dictationMenuItem?.isEnabled = true
        }
    }

    private func setStatusTitle(_ title: String) {
        statusItem?.button?.title = title
    }

    private var setupSummary: String {
        let permissionsReady = Permissions.hasAccessibility()
            && Permissions.hasInputMonitoring()
            && Permissions.hasMicrophoneAccess()
        return permissionsReady && sidecarLauncher.installationStatus().isReady
            ? "● 本机处理 · 就绪"
            : "○ 请在权限与诊断中完成设置"
    }

    func menuWillOpen(_ menu: NSMenu) {
        setupSummaryMenuItem?.title = setupSummary
        deviceInputMenuItem?.title = deviceManager.inputSourceSummary
        deviceAudioMenuItem?.title = deviceManager.audioSummary
    }

    @objc private func toggleDictation() {
        clipboardPanel.hide()
        translatePanel.hide()
        pipeline.toggleRecord()
    }

    @objc private func showClipboardHistory() {
        panel?.hide()
        translatePanel.hide()
        clipboardPanel.toggle()
    }

    @objc private func translateSelection() {
        handleTranslateSelection()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardObserver.stop()
        wirelessVoiceProvider.stop()
        sidecarLauncher.stopAll()
        if let observer = hotKeyDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            hotKeyDefaultsObserver = nil
        }
    }

    @objc func openSettings() {
        openPreferences()
        NotificationCenter.default.post(name: .inVoiceSelectSettings, object: nil)
    }

    func openDictationWorkspace() {
        openPreferences()
        NotificationCenter.default.post(name: .inVoiceSelectHome, object: nil)
    }

    func openClipboardWorkspace() {
        openPreferences()
        NotificationCenter.default.post(name: .inVoiceSelectHistory, object: nil)
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "inVoice"
        window.identifier = NSUserInterfaceItemIdentifier("inVoiceWorkspace")
        window.setFrameAutosaveName("inVoiceWorkspace")
        window.minSize = NSSize(width: 860, height: 660)
        window.setContentSize(NSSize(width: 960, height: 720))
        window.titlebarSeparatorStyle = .none
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func refreshPermissionState() {
        if Permissions.hasInputMonitoring() {
            fnMonitor.ensureEventTap()
        } else {
            fnMonitor.stop()
        }
    }
}

struct HotKeySettingsView: View {
    @State private var activationKeyCode: UInt32
    @State private var activationModifiers: UInt32
    @State private var clipboardKeyCode: UInt32
    @State private var clipboardModifiers: UInt32
    @State private var translateKeyCode: UInt32
    @State private var translateModifiers: UInt32

    init() {
        let activation = ActivationKeyPreference.load()
        _activationKeyCode = State(initialValue: activation.keyCode)
        _activationModifiers = State(initialValue: activation.modifiers)
        let clipboard = HotKeyPreference.load()
        _clipboardKeyCode = State(initialValue: clipboard.keyCode)
        _clipboardModifiers = State(initialValue: clipboard.modifiers)
        let translate = TranslateHotKeyPreference.load()
        _translateKeyCode = State(initialValue: translate.keyCode)
        _translateModifiers = State(initialValue: translate.modifiers)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferencesHeader(
                    title: "快捷键",
                    subtitle: "为高频操作设置顺手的快捷键。修改后立即生效。"
                )

                SectionCard(title: "主窗口", subtitle: "菜单栏被隐藏时，也能快速打开工作台。") {
                    HStack {
                        Text("打开 inVoice")
                            .font(.headline)
                        Spacer()
                        Text("Command+Option+P")
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }

                SectionCard(title: "语音输入", subtitle: "按住开始录音，松开后自动完成输入。") {
                    ShortcutRecorderRow(
                        title: "按住录音",
                        subtitle: "松开即完成识别与文字整理。",
                        requiresModifier: false,
                        defaultKeyCode: ActivationKeyPreference.defaultValue.keyCode,
                        defaultModifiers: ActivationKeyPreference.defaultValue.modifiers,
                        keyCode: $activationKeyCode,
                        modifiers: $activationModifiers
                    ) { keyCode, modifiers in
                        ActivationKeyPreference(keyCode: keyCode, modifiers: modifiers).save()
                    }
                }

                SectionCard(title: "剪贴板历史", subtitle: "无需切换应用，快速找到复制过的内容。") {
                    ShortcutRecorderRow(
                        title: "打开剪贴板历史",
                        subtitle: "显示或隐藏快捷面板。",
                        requiresModifier: true,
                        defaultKeyCode: HotKeyPreference.defaultValue.keyCode,
                        defaultModifiers: HotKeyPreference.defaultValue.modifiers,
                        keyCode: $clipboardKeyCode,
                        modifiers: $clipboardModifiers
                    ) { keyCode, modifiers in
                        HotKeyPreference(keyCode: keyCode, modifiers: modifiers).save()
                    }
                }

                SectionCard(title: "本地助手", subtitle: "随时翻译、改写和提问。") {
                    ShortcutRecorderRow(
                        title: "打开助手",
                        subtitle: "选中英文后打开，会自动翻译为中文。",
                        requiresModifier: true,
                        defaultKeyCode: TranslateHotKeyPreference.defaultValue.keyCode,
                        defaultModifiers: TranslateHotKeyPreference.defaultValue.modifiers,
                        keyCode: $translateKeyCode,
                        modifiers: $translateModifiers
                    ) { keyCode, modifiers in
                        TranslateHotKeyPreference(keyCode: keyCode, modifiers: modifiers).save()
                    }
                }
            }
            .padding(20)
        }
    }
}

struct PermissionsPanelView: View {
    @State private var accessibilityAllowed = Permissions.hasAccessibility()
    @State private var inputMonitoringAllowed = Permissions.hasInputMonitoring()
    @State private var microphoneAllowed = Permissions.hasMicrophoneAccess()
    @State private var microphoneStatus = Permissions.microphoneStatusLabel()
    @State private var isRequestingMicrophone = false
    @State private var installationStatus = SidecarLauncher.shared.installationStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PreferencesHeader(
                    title: "系统权限",
                    subtitle: "允许录音、快捷键和自动粘贴，即可开始听写。"
                )

                SectionCard(title: "系统授权", subtitle: "授权后返回此窗口，状态会自动更新。") {
                    PermissionRow(
                        title: "输入监控",
                        detail: "让按住说话的快捷键在其他应用中生效。",
                        statusText: inputMonitoringAllowed ? "已允许" : "未允许",
                        statusColor: inputMonitoringAllowed ? .green : .red,
                        actionTitle: "打开系统设置",
                        actionEnabled: true,
                        action: openInputMonitoringSettings
                    )

                    PermissionRow(
                        title: "辅助功能",
                        detail: "把完成的文字粘贴到原来的输入框。",
                        statusText: accessibilityAllowed ? "已允许" : "未允许",
                        statusColor: accessibilityAllowed ? .green : .red,
                        actionTitle: "打开系统设置",
                        actionEnabled: true,
                        action: openAccessibilitySettings
                    )

                    PermissionRow(
                        title: "麦克风",
                        detail: "仅在发起听写时收音。",
                        statusText: microphoneStatus,
                        statusColor: microphoneStatusColor,
                        actionTitle: microphoneActionTitle,
                        actionEnabled: !isRequestingMicrophone,
                        action: handleMicrophoneAction
                    )
                }

                DisclosureGroup("安装与诊断详情") {
                    VStack(spacing: 16) {
                SectionCard(title: "本地识别环境", subtitle: "本机模型与运行环境的安装检查。") {
                    InfoRow(
                        title: "运行环境位置",
                        value: installationStatus.sidecarRootPath ?? "尚未配置"
                    )
                    RuntimeStatusRow(
                        title: "最终语音识别",
                        isReady: installationStatus.finalASREnvironmentReady,
                        readyText: "已安装",
                        missingText: "需要安装"
                    )
                    RuntimeStatusRow(
                        title: "识别模型",
                        isReady: installationStatus.finalASRModelReady,
                        readyText: "已安装",
                        missingText: "需要安装"
                    )
                    RuntimeStatusRow(
                        title: "实时预览",
                        isReady: installationStatus.fastASREnvironmentReady,
                        readyText: "已安装",
                        missingText: "需要安装"
                    )
                    RuntimeStatusRow(
                        title: "预览模型",
                        isReady: installationStatus.fastASRModelReady,
                        readyText: "已安装",
                        missingText: "需要安装"
                    )
                }

                SectionCard(title: "诊断信息", subtitle: "遇到问题时，可查看日志确认原因。") {
                    InfoRow(
                        title: "应用位置",
                        value: Bundle.main.bundlePath
                    )
                    HStack {
                        Button("刷新状态") {
                            refreshStatuses()
                        }
                        Button("打开日志") {
                            NSWorkspace.shared.open(SidecarLauncher.shared.logsDirectoryURL())
                        }
                        Spacer()
                        if allPermissionsGranted && installationStatus.isReady {
                            Text("已就绪")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                    }.padding(.top, 12)
                }.font(.system(size: 13, weight: .medium))

                Text("密码框等安全输入场景中，macOS 会暂时阻止全局快捷键。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

        }
        .onAppear {
            refreshStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
    }

    private var allPermissionsGranted: Bool {
        accessibilityAllowed && inputMonitoringAllowed && microphoneAllowed
    }

    private var microphoneActionTitle: String {
        if isRequestingMicrophone {
            return "请求中…"
        }
        if Permissions.microphoneNeedsRequest() {
            return "允许访问"
        }
        return "打开系统设置"
    }

    private var microphoneStatusColor: Color {
        if microphoneAllowed {
            return .green
        }
        if Permissions.microphoneNeedsRequest() {
            return .orange
        }
        return .red
    }

    private func refreshStatuses() {
        accessibilityAllowed = Permissions.hasAccessibility()
        inputMonitoringAllowed = Permissions.hasInputMonitoring()
        microphoneAllowed = Permissions.hasMicrophoneAccess()
        microphoneStatus = Permissions.microphoneStatusLabel()
        installationStatus = SidecarLauncher.shared.installationStatus()
    }

    private func openAccessibilitySettings() {
        Permissions.requestAccessibilityIfNeeded()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInputMonitoringSettings() {
        Permissions.requestInputMonitoringIfNeeded()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleMicrophoneAction() {
        if Permissions.microphoneNeedsRequest() {
            isRequestingMicrophone = true
            Task {
                _ = await Permissions.requestMicrophoneIfNeeded()
                await MainActor.run {
                    isRequestingMicrophone = false
                    refreshStatuses()
                }
            }
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct RuntimeStatusRow: View {
    let title: String
    let isReady: Bool
    let readyText: String
    let missingText: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(isReady ? readyText : missingText)
                .font(.caption)
                .foregroundColor(isReady ? .green : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isReady ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let statusText: String
    let statusColor: Color
    let actionTitle: String
    let actionEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundColor(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12))
                .clipShape(Capsule())
            Button(actionTitle) {
                action()
            }
            .buttonStyle(.bordered)
            .disabled(!actionEnabled)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct PreferencesHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 23, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}

struct SectionCard<Content: View>: View {
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

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        )
    }
}

struct ShortcutRecorderRow: View {
    let title: String
    let subtitle: String?
    let requiresModifier: Bool
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    let onSave: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var localMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .font(.body)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : .primary)
            }
            HStack {
                Button("恢复默认") {
                    resetToDefault()
                }
                .buttonStyle(.link)
                Spacer()
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .secondary)
                }
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var buttonTitle: String {
        isRecording ? "Press shortcut..." : shortcutDisplay
    }

    private var shortcutDisplay: String {
        HotKeyPreference.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        statusMessage = "Recording..."
        statusIsError = false
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard isRecording else { return event }
            if handleRecordingEvent(event) {
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isRecording = false
        if statusMessage == "Recording..." {
            statusMessage = nil
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            if event.keyCode == UInt16(kVK_Function) {
                let capturedModifiers = normalizedModifiers(event.modifierFlags)
                if requiresModifier && capturedModifiers == 0 {
                    statusMessage = "请至少加上一个修饰键（⌘、⌥、⌃ 或 ⇧）。"
                    statusIsError = true
                    return true
                }
                let modifiers = requiresModifier ? capturedModifiers : 0
                return acceptShortcut(keyCode: UInt32(kVK_Function), modifiers: modifiers)
            }
            return true
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) {
                statusMessage = "已取消"
                statusIsError = false
                stopRecording()
                return true
            }
            let capturedModifiers = normalizedModifiers(event.modifierFlags)
            if requiresModifier && capturedModifiers == 0 {
                statusMessage = "请至少加上一个修饰键（⌘、⌥、⌃ 或 ⇧）。"
                statusIsError = true
                return true
            }
            return acceptShortcut(keyCode: UInt32(event.keyCode), modifiers: capturedModifiers)
        default:
            return false
        }
    }

    private func acceptShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        self.keyCode = keyCode
        self.modifiers = modifiers
        onSave(keyCode, modifiers)
        statusMessage = "已保存"
        statusIsError = false
        stopRecording()
        return true
    }

    private func resetToDefault() {
        keyCode = defaultKeyCode
        modifiers = defaultModifiers
        onSave(defaultKeyCode, defaultModifiers)
        statusMessage = "已恢复默认"
        statusIsError = false
    }

    private func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }
}

struct SelectionTranslationView: View {
    @ObservedObject var model: SelectionTranslationViewModel
    let onClose: () -> Void
    let onCopy: (String) -> Void
    let onSpeak: (String) -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var copiedText: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelBackground = Color(nsColor: .windowBackgroundColor)
    private let composerBackground = Color(nsColor: .textBackgroundColor)
    private let primaryText = Color.primary
    private let secondaryText = Color.secondary
    private let hairline = Color.primary.opacity(0.08)

    var body: some View {
        VStack(spacing: 0) {
            header
            documentBody
            composer
        }
        .frame(
            minWidth: 480,
            idealWidth: 560,
            maxWidth: .infinity,
            minHeight: 420,
            idealHeight: 640,
            maxHeight: .infinity
        )
        .background(panelBackground)
    }

    private var header: some View {
        HStack {
            Label("本机处理", systemImage: "lock").font(.system(size: 11)).foregroundStyle(secondaryText)
            Spacer()
            Button { model.newConversation() } label: { Label("新对话", systemImage: "square.and.pencil") }
                .buttonStyle(.borderless).font(.system(size: 11))
                .disabled(model.messages.isEmpty && model.composerText.isEmpty)
                .help("开始新对话")
        }.padding(.horizontal, 20).frame(height: 42)
    }

    private var documentBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("有什么想法？").font(.system(size: 26, weight: .semibold)).foregroundStyle(primaryText)
                            Text("翻译、整理，或直接提问。")
                                .font(.system(size: 13)).foregroundStyle(secondaryText)
                            ForEach(["帮我把这段话改得更简洁：", "翻译成自然英文：", "帮我整理成待办清单："], id: \.self) { suggestion in
                                Button { model.composerText = suggestion; model.requestComposerFocus() } label: {
                                    HStack { Text(suggestion); Spacer(); Image(systemName: "arrow.up.left") }
                                        .font(.system(size: 13)).padding(14)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).foregroundStyle(primaryText)
                            }
                            Text("⌘↩ 发送 · 按住 \(ActivationKeyPreference.load().displayString) 说话")
                                .font(.system(size: 11)).foregroundStyle(secondaryText)
                        }.padding(.vertical, 28)
                    }
                    ForEach(model.messages) { message in
                        messageView(message)
                    }

                    if case .error(let message) = model.state {
                        errorCard(message)
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 24)
                .padding(.top, 25)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.messages) { _ in
                if let last = model.messages.last?.id {
                    withAnimation(reduceMotion || model.state == .translating ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: SelectionTranslationViewModel.ChatMessage) -> some View {
        if message.role == .assistant {
            assistantDocument(message)
        } else {
            HStack {
                Spacer(minLength: 90)
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundColor(primaryText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .id(message.id)
        }
    }

    private func assistantDocument(_ message: SelectionTranslationViewModel.ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if message.content.isEmpty && model.state == .translating {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在回复…")
                        .font(.system(size: 15))
                        .foregroundColor(secondaryText)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !message.content.isEmpty {
                RichMarkdownDocumentView(source: message.content, onCopy: onCopy)
                    .foregroundColor(primaryText)
                responseActions(for: message.content)
            }
        }
        .id(message.id)
    }

    private func responseActions(for text: String) -> some View {
        HStack(spacing: 14) {
            responseActionButton(copiedText == text ? "checkmark" : "square.on.square", help: "复制回复") {
                onCopy(text)
                copiedText = text
            }
            responseActionButton("speaker.wave.2", help: "朗读") { onSpeak(text) }
        }
        .foregroundColor(secondaryText)
    }

    private func responseActionButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("输入想法…", text: $model.composerText, axis: .vertical)
                .font(.system(size: 15))
                .foregroundColor(primaryText)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .accessibilityLabel("助手输入框")

            if model.state == .translating {
                Button {
                    model.stopGenerating()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .background(Color.primary.opacity(0.08), in: Circle())
                .help("停止生成").accessibilityLabel("停止生成")
            } else {
                Button {
                    model.sendComposerMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(canSend ? .white : .secondary)
                .background(canSend ? Color.accentColor : Color.primary.opacity(0.07), in: Circle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .help("发送（⌘ Return）").accessibilityLabel("发送")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(minHeight: 50)
        .background(composerBackground, in: Capsule())
        .overlay {
            Capsule()
                .stroke(hairline)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 9)
        .onChange(of: model.composerFocusRequest) { _ in
            DispatchQueue.main.async {
                isComposerFocused = true
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isComposerFocused = true
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(secondaryText)
            Spacer()
            if model.messages.contains(where: { $0.role == .user }) {
                Button("重试") {
                    model.retryTranslation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        model.state != .translating
            && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

private struct RichMarkdownDocumentView: View {
    let source: String
    let onCopy: (String) -> Void

    private var blocks: [MarkdownDocumentBlock] {
        MarkdownDocumentParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocumentBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineMarkdown(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 5 : 2)
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 22) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 4)
                    .frame(minHeight: 24)
                inlineMarkdown(text)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(4)
            }
            .padding(.vertical, 6)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 5, height: 5)
                        inlineMarkdown(item)
                            .font(.system(size: 15))
                    }
                }
            }
            .padding(.leading, 5)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).")
                            .font(.system(size: 15).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        inlineMarkdown(item)
                            .font(.system(size: 15))
                    }
                }
            }
        case .code(let language, let content):
            CodeDocumentBlock(language: language, content: content) {
                onCopy(content)
            }
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 22, weight: .bold)
        case 2:
            return .system(size: 19, weight: .bold)
        case 3:
            return .system(size: 17, weight: .semibold)
        default:
            return .system(size: 16, weight: .semibold)
        }
    }
}

private struct CodeDocumentBlock: View {
    let language: String?
    let content: String
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(languageLabel)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        )
    }

    private var languageLabel: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "纯文本" : trimmed
    }
}

@MainActor
final class SelectionTranslationPanelController {
    static let shared = SelectionTranslationPanelController()

    private let viewModel = SelectionTranslationViewModel()
    private let speechSynthesizer = NSSpeechSynthesizer()
    private var panel: SelectionTranslationPanel?
    private var keyMonitor: Any?

    private init() {
        createPanel()
    }

    func show(selection: SelectionCaptureResult) {
        if panel == nil {
            createPanel()
        }
        viewModel.start(selection: selection)
        panel?.show()
        focusComposer()
        startKeyMonitor()
    }

    #if DEBUG
    func showPreview() {
        if UserDefaults.standard.bool(forKey: "INVOICE_EMPTY_DIALOG_PREVIEW") {
            viewModel.start(selection: .empty(.clipboardUnchanged))
        } else {
            viewModel.loadPreview(
                selectedText: """
                Explain when the selected-English translation behavior runs.
                """,
                translation: """
                这里的“时”指的是这个触发逻辑里的时机：

                **选中文本时** → 打开这个极简对话框，并自动把选中的英文作为第一条上下文，默认执行「英文 → 中文」。

                **没有选中文本时** → 打开的完全相同的对话框，只是没有自动任务，焦点直接落在输入框，你可以直接问任何问题。

                所以产品本质不是“翻译窗口”，而是一个极简本地 AI 对话框。翻译只是其中一个快捷触发行为：

                > 选中英文 + 快捷键 = 自动帮你发起一次“翻译成中文”的对话。

                之后你继续在下面输入，比如“解释一下这段”“更口语一点”“这里为什么这么写”，都应该按普通对话处理，而不是继续被锁死在翻译模式里。

                这样理解的话，UI 甚至不需要出现「English → Chinese」「Translation」之类的标题。
                """
            )
        }
        panel?.show()
        focusComposer()
        startKeyMonitor()
    }
    #endif

    func hide() {
        panel?.hide()
        stopKeyMonitor()
        viewModel.cancel()
        speechSynthesizer.stopSpeaking()
    }

    private func createPanel() {
        let view = SelectionTranslationView(
            model: viewModel,
            onClose: { [weak self] in
                self?.hide()
            },
            onCopy: { [weak self] text in
                self?.copyText(text)
            },
            onSpeak: { [weak self] text in
                self?.speak(text)
            }
        )
        panel = SelectionTranslationPanel(rootView: view)
        panel?.onClose = { [weak self] in self?.hide() }
    }

    private func focusComposer() {
        DispatchQueue.main.async { [weak self] in
            self?.panel?.makeKey()
            self?.viewModel.requestComposerFocus()
        }
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        ClipboardObserver.shared.markInternalWrite()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking()
        } else {
            speechSynthesizer.startSpeaking(text)
        }
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53,
                  (self.panel?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
            self.hide()
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
