import XCTest
@testable import VoiceOpsCore

final class CodexSubmitShortcutPlanTests: XCTestCase {
    func testSubmitIsCodexScopedAndUsesPlainReturn() {
        XCTAssertTrue(
            CodexSubmitShortcutPlan.shouldSubmit(
                frontmostBundleIdentifier: "com.openai.codex"
            )
        )
        XCTAssertFalse(
            CodexSubmitShortcutPlan.shouldSubmit(
                frontmostBundleIdentifier: "com.google.Chrome"
            )
        )
        XCTAssertEqual(
            CodexSubmitShortcutPlan.events(returnKeyCode: 36),
            [
                PasteShortcutEvent(keyCode: 36, isKeyDown: true, usesCommand: false),
                PasteShortcutEvent(keyCode: 36, isKeyDown: false, usesCommand: false)
            ]
        )
    }
}
