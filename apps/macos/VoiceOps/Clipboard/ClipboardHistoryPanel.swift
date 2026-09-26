import AppKit
import SwiftUI

final class ClipboardHistoryPanel: NSPanel {
    init(rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        let rect = NSRect(x: 0, y: 0, width: 600, height: 490)
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
        hidesOnDeactivate = false

        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        positionCenter()
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
