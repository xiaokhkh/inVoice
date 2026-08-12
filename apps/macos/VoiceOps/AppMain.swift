import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct VoiceOpsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusIdleTitle = "konh"
    private var statusItem: NSStatusItem?
    private var panel: OverlayPanel?
    private var previewPanel: PreviewPanel?
    private let previewModel = PreviewModel()
    private var clipboardHotKeyPreference = HotKeyPreference.defaultValue
    private var activationPreference = ActivationKeyPreference.defaultValue
    private var translateHotKeyPreference = TranslateHotKeyPreference.defaultValue
    private var hotKeyDefaultsObserver: Any?
    private var settingsWindowController: NSWindowController?
    private var preferencesHotKey: HotKeyService?
    private let fnMonitor = FnKeyMonitor()
    private let fnSession = FnSessionController()
    private let clipboardObserver = ClipboardObserver.shared
    private let clipboardPanel = ClipboardHistoryPanelController.shared
    private let translatePanel = SelectionTranslationPanelController.shared
    private let sidecarLauncher = SidecarLauncher.shared
    private let selectionCapture = SelectionCaptureService.shared
    private var fnHoldActive = false
    private var cancellables = Set<AnyCancellable>()

    private let pipeline = PipelineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupOverlay()
        setupPreviewPanel()
        setupShortcuts()
        setupPreferencesHotKey()
        setupFnMonitor()
        bindPipeline()
        clipboardObserver.start()
        sidecarLauncher.startAll()

        if ProcessInfo.processInfo.environment["VOICEOPS_OPEN_PREFERENCES"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.openPreferences()
            }
        }
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

        let menu = NSMenu()
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        let revealItem = NSMenuItem(title: "Reveal App in Finder", action: #selector(revealApp), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")

        preferencesItem.target = self
        revealItem.target = self
        quitItem.target = self

        menu.addItem(preferencesItem)
        menu.addItem(revealItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setupOverlay() {
        let view = OverlayView().environmentObject(pipeline)
        panel = OverlayPanel(rootView: view)
        panel?.onSubmit = { [weak self] in
            self?.pipeline.insertToFocusedApp()
        }
        panel?.onCancel = { [weak self] in
            self?.pipeline.cancel()
        }
    }

    private func setupPreviewPanel() {
        let view = PreviewView(model: previewModel)
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
                    self?.openPreferences()
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
            self?.previewModel.text = text
        }
        if Permissions.hasInputMonitoring() {
            fnMonitor.start()
        }
    }

    private func handleFnDown() {
        guard !fnHoldActive else { return }
        guard Permissions.hasAccessibility() else {
            openPreferences()
            return
        }
        fnHoldActive = true
        clipboardPanel.hide()
        panel?.hide()
        previewModel.text = ""
        previewModel.state = .recording
        previewPanel?.show()
        Task { await fnSession.startSession() }
    }

    private func handleFnUp() {
        guard fnHoldActive else { return }
        fnHoldActive = false
        fnSession.endSession()
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
        case .idle:
            previewModel.state = .idle
            if !fnHoldActive {
                previewPanel?.hide()
            }
        case .recording:
            previewModel.state = .recording
        case .processing:
            previewModel.state = .processing
        }
    }

    private func bindPipeline() {
        pipeline.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if self?.fnHoldActive == true {
                    self?.panel?.hide()
                    return
                }
                switch state {
                case .idle:
                    self?.panel?.hide()
                default:
                    self?.panel?.show()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecarLauncher.stopAll()
        if let observer = hotKeyDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            hotKeyDefaultsObserver = nil
        }
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
        window.title = "Preferences"
        window.setContentSize(NSSize(width: 560, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable]
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
                    title: "Shortcuts",
                    subtitle: "Control how you start recording, search clipboard, and translate selections."
                )

                SectionCard(title: "Preferences", subtitle: "Open settings even when the menu bar item is hidden.") {
                    HStack {
                        Text("Open Preferences")
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

                SectionCard(title: "Activation", subtitle: "Press and hold to start recording.") {
                    ShortcutRecorderRow(
                        title: "Hold to record",
                        subtitle: "Release to finish and process.",
                        requiresModifier: false,
                        defaultKeyCode: ActivationKeyPreference.defaultValue.keyCode,
                        defaultModifiers: ActivationKeyPreference.defaultValue.modifiers,
                        keyCode: $activationKeyCode,
                        modifiers: $activationModifiers
                    ) { keyCode, modifiers in
                        ActivationKeyPreference(keyCode: keyCode, modifiers: modifiers).save()
                    }
                }

                SectionCard(title: "Clipboard History", subtitle: "Quickly reuse previous clipboard items.") {
                    ShortcutRecorderRow(
                        title: "Open clipboard history",
                        subtitle: "Toggles the clipboard history panel.",
                        requiresModifier: true,
                        defaultKeyCode: HotKeyPreference.defaultValue.keyCode,
                        defaultModifiers: HotKeyPreference.defaultValue.modifiers,
                        keyCode: $clipboardKeyCode,
                        modifiers: $clipboardModifiers
                    ) { keyCode, modifiers in
                        HotKeyPreference(keyCode: keyCode, modifiers: modifiers).save()
                    }
                }

                SectionCard(title: "Selection Translation", subtitle: "Translate selected text via Ollama.") {
                    ShortcutRecorderRow(
                        title: "Translate selected text",
                        subtitle: "Shows translation using the local Ollama model.",
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

struct PreferencesView: View {
    @State private var selectedTab: Int

    init() {
        let needsPermission = !Permissions.hasAccessibility()
            || !Permissions.hasInputMonitoring()
            || !Permissions.hasMicrophoneAccess()
        _selectedTab = State(initialValue: needsPermission ? 1 : 2)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HotKeySettingsView()
                .tag(0)
                .tabItem {
                    Text("Shortcuts")
                }
            PermissionsPanelView()
                .tag(1)
                .tabItem {
                    Text("Permissions")
                }
            PromptSettingsView()
                .tag(2)
                .tabItem {
                    Text("LLM")
                }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

struct PermissionsPanelView: View {
    @State private var accessibilityAllowed = Permissions.hasAccessibility()
    @State private var inputMonitoringAllowed = Permissions.hasInputMonitoring()
    @State private var microphoneAllowed = Permissions.hasMicrophoneAccess()
    @State private var microphoneStatus = Permissions.microphoneStatusLabel()
    @State private var isRequestingMicrophone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferencesHeader(
                    title: "Permissions",
                    subtitle: "Grant the permissions below to keep shortcuts and recording working across apps."
                )

                SectionCard(title: "System Access", subtitle: "Required for global shortcuts and focus control.") {
                    PermissionRow(
                        title: "Input Monitoring",
                        detail: "Required for global shortcuts across all apps.",
                        statusText: inputMonitoringAllowed ? "Allowed" : "Denied",
                        statusColor: inputMonitoringAllowed ? .green : .red,
                        actionTitle: "Open Settings",
                        actionEnabled: true,
                        action: openInputMonitoringSettings
                    )

                    PermissionRow(
                        title: "Accessibility",
                        detail: "Required to inject text and control focus.",
                        statusText: accessibilityAllowed ? "Allowed" : "Denied",
                        statusColor: accessibilityAllowed ? .green : .red,
                        actionTitle: "Open Settings",
                        actionEnabled: true,
                        action: openAccessibilitySettings
                    )

                    PermissionRow(
                        title: "Microphone",
                        detail: "Required to capture audio for transcription.",
                        statusText: microphoneStatus,
                        statusColor: microphoneStatusColor,
                        actionTitle: microphoneActionTitle,
                        actionEnabled: !isRequestingMicrophone,
                        action: handleMicrophoneAction
                    )
                }

                SectionCard(title: "Diagnostics", subtitle: "Helpful for support or debugging.") {
                    InfoRow(
                        title: "App Path",
                        value: Bundle.main.bundlePath
                    )
                    HStack {
                        Button("Refresh Status") {
                            refreshStatuses()
                        }
                        Spacer()
                        if allPermissionsGranted {
                            Text("All set")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Text("Note: macOS blocks global shortcuts while Secure Input is active (for example in password fields).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(20)
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
            return "Requesting..."
        }
        if Permissions.microphoneNeedsRequest() {
            return "Request Access"
        }
        return "Open Settings"
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

private struct PreferencesHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

private struct SectionCard<Content: View>: View {
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
                Button("Reset to Default") {
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
                    statusMessage = "Add at least one modifier."
                    statusIsError = true
                    return true
                }
                let modifiers = requiresModifier ? capturedModifiers : 0
                return acceptShortcut(keyCode: UInt32(kVK_Function), modifiers: modifiers)
            }
            return true
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) {
                statusMessage = "Canceled"
                statusIsError = false
                stopRecording()
                return true
            }
            let capturedModifiers = normalizedModifiers(event.modifierFlags)
            if requiresModifier && capturedModifiers == 0 {
                statusMessage = "Add at least one modifier."
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
        statusMessage = "Saved"
        statusIsError = false
        stopRecording()
        return true
    }

    private func resetToDefault() {
        keyCode = defaultKeyCode
        modifiers = defaultModifiers
        onSave(defaultKeyCode, defaultModifiers)
        statusMessage = "Reset to default"
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

    private let client = OfflineLLMClient()
    private var task: Task<Void, Never>?
    private var pendingAssistantID: UUID?

    func start(selection: SelectionCaptureResult) {
        task?.cancel()
        task = nil
        messages = []
        composerText = ""
        pendingAssistantID = nil

        switch selection {
        case .success(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .error("No text selected.")
                return
            }
            sendUserMessage(trimmed)
        case .empty, .failure:
            state = .error(selection.userMessage)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingAssistantID = nil
    }

    func sendComposerMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        sendUserMessage(text, kind: .chat)
    }

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
            await self?.runTranslation()
        }
    }

    private func runTranslation() async {
        do {
            let payload = messages.filter { message in
                !(message.role == .assistant && message.content.isEmpty)
            }.map { message in
                OfflineLLMClient.ChatMessage(
                    role: message.role == .user ? "user" : "assistant",
                    content: message.content,
                    applyTemplate: message.role == .user && message.kind == .selection
                )
            }
            let assistantID = pendingAssistantID
            let translated = try await client.chatStream(
                messages: payload,
                profile: .translation
            ) { [weak self] delta in
                self?.appendAssistantDelta(delta, assistantID: assistantID)
            }
            if Task.isCancelled {
                return
            }
            finalizeAssistantMessage(translated, assistantID: assistantID)
            state = .ready
        } catch {
            if Task.isCancelled {
                return
            }
            state = .error("Translation failed.")
        }
    }

    private func appendAssistantDelta(_ delta: String, assistantID: UUID?) {
        guard let assistantID else { return }
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content += delta
    }

    private func finalizeAssistantMessage(_ fullText: String, assistantID: UUID?) {
        guard let assistantID else { return }
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content = fullText
        pendingAssistantID = nil
    }
}

struct SelectionTranslationView: View {
    @ObservedObject var model: SelectionTranslationViewModel
    let onClose: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chatBody
            composer
        }
        .padding(16)
        .frame(width: 600, height: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Translation Chat")
                    .font(.headline)
                Text("Chat with the local Ollama model about your selection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusView
            Button("Close") {
                onClose()
            }
            .buttonStyle(.bordered)
        }
    }

    private var chatBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            if case .error(let message) = model.state {
                                Text(message)
                                    .font(.headline)
                                Text("Select text and trigger the translate shortcut to try again.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No messages yet")
                                    .font(.headline)
                                Text("Select text and trigger the translate shortcut to start.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 12)
                    } else {
                        ForEach(model.messages) { message in
                            chatBubble(for: message)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages) { _ in
                if let last = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
    }

    private func chatBubble(for message: SelectionTranslationViewModel.ChatMessage) -> some View {
        HStack {
            if message.role == .assistant {
                bubbleContent(message, alignment: .leading, background: Color.white.opacity(0.08))
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubbleContent(message, alignment: .trailing, background: Color.accentColor.opacity(0.18))
            }
        }
        .id(message.id)
    }

    private func bubbleContent(
        _ message: SelectionTranslationViewModel.ChatMessage,
        alignment: HorizontalAlignment,
        background: Color
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label(for: message))
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(background)
        )
        .frame(maxWidth: 420, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue the conversation")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextEditor(text: $model.composerText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 90)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2))
                    )

                VStack(spacing: 8) {
                    Button("Send") {
                        model.sendComposerMessage()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state == .translating)

                    Button("Copy Last") {
                        if let last = model.messages.last(where: { $0.role == .assistant }) {
                            onCopy(last.content)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.messages.first(where: { $0.role == .assistant }) == nil)
                }
            }

            HStack {
                Text("Esc to close")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func label(for message: SelectionTranslationViewModel.ChatMessage) -> String {
        switch message.role {
        case .assistant:
            return "Assistant"
        case .user:
            return message.kind == .selection ? "Selected" : "You"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .translating:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Translating")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }
}

@MainActor
final class SelectionTranslationPanelController {
    static let shared = SelectionTranslationPanelController()

    private let viewModel = SelectionTranslationViewModel()
    private var panel: SelectionTranslationPanel?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {
        createPanel()
    }

    func show(selection: SelectionCaptureResult) {
        if panel == nil {
            createPanel()
        }
        viewModel.start(selection: selection)
        panel?.show()
        startKeyMonitor()
    }

    func hide() {
        panel?.hide()
        stopKeyMonitor()
        viewModel.cancel()
    }

    private func createPanel() {
        let view = SelectionTranslationView(
            model: viewModel,
            onClose: { [weak self] in
                self?.hide()
            },
            onCopy: { [weak self] text in
                self?.copyText(text)
            }
        )
        panel = SelectionTranslationPanel(rootView: view)
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        ClipboardObserver.shared.markInternalWrite()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func startKeyMonitor() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SelectionTranslationPanelController>.fromOpaque(refcon).takeUnretainedValue()
            if type != .keyDown {
                return Unmanaged.passUnretained(event)
            }
            return controller.handleEventTap(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopKeyMonitor() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEventTap(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard panel?.isVisible == true else { return Unmanaged.passUnretained(cgEvent) }
        guard let event = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }

        if event.keyCode == 53 { // Esc
            hide()
            return nil
        }

        return Unmanaged.passUnretained(cgEvent)
    }
}
