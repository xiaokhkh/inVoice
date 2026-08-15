import Foundation

struct PasteShortcutEvent: Equatable, Sendable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let usesCommand: Bool
}

enum PasteShortcutPlan {
    static func events(vKeyCode: UInt16) -> [PasteShortcutEvent] {
        [
            PasteShortcutEvent(
                keyCode: vKeyCode,
                isKeyDown: true,
                usesCommand: true
            ),
            PasteShortcutEvent(
                keyCode: vKeyCode,
                isKeyDown: false,
                usesCommand: true
            )
        ]
    }
}

enum CodexSubmitShortcutPlan {
    static let targetBundleIdentifier = "com.openai.codex"

    static func shouldSubmit(frontmostBundleIdentifier: String?) -> Bool {
        frontmostBundleIdentifier == targetBundleIdentifier
    }

    static func events(returnKeyCode: UInt16) -> [PasteShortcutEvent] {
        [
            PasteShortcutEvent(
                keyCode: returnKeyCode,
                isKeyDown: true,
                usesCommand: false
            ),
            PasteShortcutEvent(
                keyCode: returnKeyCode,
                isKeyDown: false,
                usesCommand: false
            )
        ]
    }
}
