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
