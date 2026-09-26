// Isolated UI fixture using the shipping views and SQLite store. No services or clipboard capture run.
import AppKit
import SwiftUI

extension Notification.Name {
    static let inVoiceOpenHistory = Notification.Name("inVoiceOpenHistory")
}
struct PreferencesHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundColor(.secondary)
        }
    }
}

@main
struct ClipboardPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var panel: ClipboardHistoryPanelController!
    private var directory: URL!
    private var originalClipboard: [NSPasteboardItem] = []
    private var texts: [String] = []
    private var imageData = Data()

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { source in
            let item = NSPasteboardItem()
            for type in source.types { if let data = source.data(forType: type) { item.setData(data, forType: type) } }
            return item
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("inVoice-clipboard-ui-\(UUID())")
        let store = ClipboardStore(directory: directory)
        texts = [
            "QA · 常用回复\n谢谢你的反馈，我会在今天下午更新进展。",
            "QA · Release notes\n" + String(repeating: "每一次复制，都值得被妥善保存。\nSearch, preview, and reuse your ideas.\n", count: 20),
            "QA · 代码片段\n  if ready {\n    start()\n  }\n",
            "QA · 进度 100% · file_name · 路径 \\assets",
            "QA · Please finish the experience improvements by Friday."
        ]
        for text in texts.dropLast() { store.recordSystemText(text, appBundleID: "com.apple.TextEdit") }
        if let first = store.getRecentItems(query: "常用回复").first { store.setPinned(true, for: first.id) }
        store.recordVoiceOpsText(sessionID: UUID(), text: texts.last!, selectedText: nil, voiceIntent: "translateAndPolish", llmUsed: "local", appBundleID: nil)
        let image = NSImage(size: NSSize(width: 1600, height: 1000))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1600, height: 1000)).fill()
        ("inVoice\nClipboard preview" as NSString).draw(at: NSPoint(x: 110, y: 420), withAttributes: [.font: NSFont.systemFont(ofSize: 100, weight: .semibold), .foregroundColor: NSColor.white])
        image.unlockFocus()
        imageData = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        store.recordSystemImage(imageData, appBundleID: "com.apple.Preview", originalPath: "/tmp/QA-设计预览.png")
        _ = store.counts()
        panel = ClipboardHistoryPanelController(store: store)
        let view = PreviewWorkspace(store: store, panel: panel)
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "inVoice Clipboard QA"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 850, height: 740))
        window.center()
        window.makeKeyAndOrderFront(nil)
        let menu = NSMenu()
        let appMenu = NSMenuItem(); menu.addItem(appMenu); appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let pb = NSPasteboard.general
        if texts.contains(pb.string(forType: .string) ?? "") || pb.data(forType: .png) == imageData {
            pb.clearContents()
            if !originalClipboard.isEmpty { pb.writeObjects(originalClipboard) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct PreviewWorkspace: View {
    let store: ClipboardStore
    let panel: ClipboardHistoryPanelController
    @State private var targetText = ""
    var body: some View {
        VStack(spacing: 0) {
            HistoryWorkspaceView(store: store)
            Divider()
            HStack {
                TextField("粘贴测试目标", text: $targetText).textFieldStyle(.roundedBorder)
                Button("打开快捷面板 ⌘J") { panel.show() }.keyboardShortcut("j")
            }.padding(12)
        }.tint(.indigo).background(Color(nsColor: .windowBackgroundColor))
    }
}
