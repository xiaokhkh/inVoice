import XCTest
@testable import VoiceOpsCore

final class MarkdownDocumentParserTests: XCTestCase {
    func testParsesDocumentBlocksUsedByTheTranslationPanel() {
        let markdown = """
        ## Overall structure

        Intro with **emphasis**.

        > A managed Mac plus a private runner.

        - Preserve commands
        - Translate prose

        1. Select English
        2. Open the panel

        ```swift
        let language = "zh-Hans"
        ```
        """

        XCTAssertEqual(
            MarkdownDocumentParser.parse(markdown),
            [
                .heading(level: 2, text: "Overall structure"),
                .paragraph("Intro with **emphasis**."),
                .quote("A managed Mac plus a private runner."),
                .unorderedList(["Preserve commands", "Translate prose"]),
                .orderedList(["Select English", "Open the panel"]),
                .code(language: "swift", content: "let language = \"zh-Hans\"")
            ]
        )
    }

    func testTreatsAnUnfinishedStreamingFenceAsCode() {
        let markdown = """
        Result:

        ```sh
        xcodebuild -scheme VoiceOps
        """

        XCTAssertEqual(
            MarkdownDocumentParser.parse(markdown),
            [
                .paragraph("Result:"),
                .code(language: "sh", content: "xcodebuild -scheme VoiceOps")
            ]
        )
    }

    func testNormalizesLineEndingsAndDividers() {
        XCTAssertEqual(
            MarkdownDocumentParser.parse("First\r\n\r\n---\r\n\r\nSecond"),
            [.paragraph("First"), .divider, .paragraph("Second")]
        )
    }
}
