import AppKit
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController {
    static let shared = ClipboardHistoryPanelController()
    private let viewModel: ClipboardHistoryViewModel
    private var panel: ClipboardHistoryPanel?
    private var previewPanel: ImagePreviewPanel?
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var previewTask: Task<Void, Never>?
    private var previewedItemID: UUID?
    private var targetPID: pid_t?

    init(store: ClipboardStore = .shared) {
        viewModel = ClipboardHistoryViewModel(store: store)
        createPanel()
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    func show() {
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        viewModel.refresh(resetSelection: true)
        panel?.show()
        hidePreview()
        startKeyMonitor()
    }

    func hide(resetSearch: Bool = true) {
        panel?.hide()
        stopKeyMonitor()
        hidePreview()
        if resetSearch { viewModel.clearQuery() }
    }

    private func paste(_ item: ClipboardItem) {
        guard !viewModel.isSearching else { viewModel.showMessage("正在搜索，请稍候"); return }
        let destination = targetPID
        hide(resetSearch: false)
        Task {
            let pasted = await viewModel.pasteItem(item, targetPID: destination)
            if !pasted {
                panel?.show()
                startKeyMonitor()
            } else { viewModel.clearQuery() }
        }
    }

    private func createPanel() {
        panel = ClipboardHistoryPanel(rootView: ClipboardHistoryView(
            viewModel: viewModel,
            onInject: { [weak self] item in self?.paste(item) },
            onHoverImage: { [weak self] item in self?.handleHover(item: item) },
            onManage: { [weak self] in
                self?.hide()
                NotificationCenter.default.post(name: .inVoiceOpenHistory, object: nil)
            }
        ))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel?.isVisible == true, self.panel?.isKeyWindow == false else { return }
                self.hide()
            }
        }
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        // A native field editor handles IME, selection, paste and ordinary text editing.
        // This monitor is scoped to our key window; other applications keep their keystrokes.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true else { return false }
        let editor = panel?.firstResponder as? NSTextView
        // Arrow/Return/Escape belong to the input method while composing Chinese, Japanese, etc.
        if editor?.hasMarkedText() == true { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            switch event.keyCode {
            case 8 where editor?.selectedRange().length ?? 0 == 0: viewModel.copySelected(); return true
            case 51, 117: viewModel.deleteSelected(); return true
            case 6 where viewModel.query.isEmpty && viewModel.counts.undoable > 0: viewModel.undoDeletion(); return true
            default: return false
            }
        }
        guard !mods.contains(.option), !mods.contains(.control), !mods.contains(.shift) else { return false }
        switch event.keyCode {
        case 53: hide(); return true
        case 126: viewModel.moveSelection(delta: -1); return true
        case 125: viewModel.moveSelection(delta: 1); return true
        case 36, 76:
            if let item = viewModel.selectedItem() { paste(item) }
            return true
        default: return false
        }
    }

    private func handleHover(item: ClipboardItem?) {
        guard let item, let path = item.contentImagePath else { hidePreview(); return }
        guard previewedItemID != item.id else { return }
        hidePreview()
        previewedItemID = item.id
        previewTask = Task {
            let image = await ClipboardImageLoader.shared.image(path: path, pixels: 700)
            guard !Task.isCancelled, let image, previewedItemID == item.id, panel?.isVisible == true else { return }
            showPreview(image: image)
        }
    }

    private func showPreview(image: NSImage) {
        if previewPanel == nil {
            previewPanel = ImagePreviewPanel(rootView: ImagePreviewView(image: image))
        } else {
            previewPanel?.update(image: image)
        }
        previewPanel?.show(at: NSEvent.mouseLocation)
    }

    private func hidePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewedItemID = nil
        previewPanel?.hide()
    }
}

private final class ImagePreviewPanel: NSPanel {
    private let hosting: NSHostingView<ImagePreviewView>

    init(rootView: ImagePreviewView) {
        hosting = NSHostingView(rootView: rootView)
        let rect = NSRect(x: 0, y: 0, width: 280, height: 200)
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true

        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(image: NSImage) {
        hosting.rootView = ImagePreviewView(image: image)
    }

    func show(at point: NSPoint) {
        position(near: point)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    private func position(near point: NSPoint) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        var x = point.x + 16
        var y = point.y - size.height - 16
        if x + size.width > visible.maxX {
            x = visible.maxX - size.width - 8
        }
        if x < visible.minX {
            x = visible.minX + 8
        }
        if y < visible.minY {
            y = point.y + 16
        }
        if y + size.height > visible.maxY {
            y = visible.maxY - size.height - 8
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct ImagePreviewView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 280, height: 200)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12))
            )
    }
}
