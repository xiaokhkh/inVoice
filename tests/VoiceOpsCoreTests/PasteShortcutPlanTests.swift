import XCTest
@testable import VoiceOpsCore

final class PasteShortcutPlanTests: XCTestCase {
    func testPasteUsesOnlyCommandVDownAndUp() {
        let events = PasteShortcutPlan.events(vKeyCode: 9)

        XCTAssertEqual(
            events,
            [
                PasteShortcutEvent(keyCode: 9, isKeyDown: true, usesCommand: true),
                PasteShortcutEvent(keyCode: 9, isKeyDown: false, usesCommand: true)
            ]
        )
    }
}
