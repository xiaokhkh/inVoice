import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    init(rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        let rect = NSRect(x: 0, y: 0, width: 380, height: 220)
        super.init(contentRect: rect, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        contentView = hosting
    }

    override var canBecomeKey: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Numpad Enter
            onSubmit?()
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    func show() {
        positionTopCenter()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = self.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class SelectionTranslationPanel: NSPanel {
    private var didPositionInitialFrame = false

    init(rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        let rect = NSRect(x: 0, y: 0, width: 620, height: 706)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        minSize = NSSize(width: 560, height: 520)
        maxSize = NSSize(width: 920, height: 1000)
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        if !didPositionInitialFrame {
            positionCenter()
            didPositionInitialFrame = true
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }

    private func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = self.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
