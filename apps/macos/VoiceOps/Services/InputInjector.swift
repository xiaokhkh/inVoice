import Cocoa
import ApplicationServices

final class InputInjector {
    func pressReturn() -> Bool {
        guard Permissions.hasAccessibility() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let returnKey: CGKeyCode = 36
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: returnKey,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: returnKey,
            keyDown: false
        ) else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @MainActor func insertViaPaste(_ text: String, restoreClipboard: Bool = true) -> Bool {
        guard Permissions.hasAccessibility() else { return false }

        ClipboardObserver.shared.markInternalWrite()
        let pb = NSPasteboard.general
        let backup = restoreClipboard ? (pb.pasteboardItems ?? []) : []
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let kV: CGKeyCode = 9 // US layout 'v'

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
        }

        post(kV, down: true, flags: [.maskCommand])
        post(kV, down: false, flags: [.maskCommand])

        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pb.clearContents()
                for item in backup { pb.writeObjects([item]) }
            }
        }
        return true
    }

    func insertViaTyping(_ text: String) -> Bool {
        guard Permissions.hasAccessibility() else { return false }
        guard !text.isEmpty else { return true }

        let src = CGEventSource(stateID: .combinedSessionState)
        let chars = Array(text.utf16)

        chars.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        return true
    }
}
