import AppKit
import SwiftUI

enum PreviewLayout {
    static let compactContentWidth: CGFloat = 38
    static let maximumContentWidth: CGFloat = 300
    static let contentHeight: CGFloat = 38
    static let renderingInset: CGFloat = 3

    static var compactPanelWidth: CGFloat {
        compactContentWidth + renderingInset * 2
    }

    static var panelHeight: CGFloat {
        contentHeight + renderingInset * 2
    }
}

final class PreviewPanel: NSPanel {
    private var maximumLiveWidth = PreviewLayout.compactContentWidth
    private var transitionGeneration = 0

    init(rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        let rect = NSRect(
            x: 0,
            y: 0,
            width: PreviewLayout.compactPanelWidth,
            height: PreviewLayout.panelHeight
        )
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        appearance = NSAppearance(named: .darkAqua)

        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        transitionGeneration &+= 1
        alphaValue = 1
        positionBottomCenter()
        orderFrontRegardless()
    }

    func hide() {
        transitionGeneration &+= 1
        alphaValue = 1
        orderOut(nil)
    }

    func mergeIntoTarget(completion: @escaping () -> Void) {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            completion()
        }
    }

    func resetToListening() {
        maximumLiveWidth = PreviewLayout.compactContentWidth
        resize(toContentWidth: PreviewLayout.compactContentWidth, animated: false)
    }

    func update(text: String, state: PreviewModel.State, animated: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textWidth = ceil(
            (trimmed as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]
            ).width
        )

        let width: CGFloat
        switch state {
        case .idle:
            width = PreviewLayout.compactContentWidth
        case .recording, .processing:
            let proposed = trimmed.isEmpty ? PreviewLayout.compactContentWidth : 65 + textWidth
            maximumLiveWidth = max(maximumLiveWidth, proposed)
            width = maximumLiveWidth
        case .result, .failure:
            width = max(118, 92 + textWidth)
        }
        resize(
            toContentWidth: min(state == .failure ? 420 : PreviewLayout.maximumContentWidth, width),
            animated: animated
        )
    }

    private func resize(toContentWidth contentWidth: CGFloat, animated: Bool) {
        let panelWidth = contentWidth + PreviewLayout.renderingInset * 2
        guard abs(frame.width - panelWidth) > 0.5 else { return }
        let targetFrame = NSRect(
            x: frame.midX - panelWidth / 2,
            y: frame.minY,
            width: panelWidth,
            height: PreviewLayout.panelHeight
        )
        guard animated, isVisible else {
            setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            animator().setFrame(targetFrame, display: true)
        }
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = self.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
