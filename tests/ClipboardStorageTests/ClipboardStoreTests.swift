import XCTest
import SQLite3
@testable import ClipboardStorage

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-clipboard-tests-\(UUID())")
        store = ClipboardStore(directory: directory)
    }
    override func tearDownWithError() throws {
        _ = store.counts() // drain asynchronous writes before releasing the database
        store = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func record(_ text: String) { store.recordSystemText(text, appBundleID: "com.apple.TextEdit") }
    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK)
    }

    func testTextPreservesIndentationAndDistinctWhitespace() {
        let code = "  if ready {\n    run()\n  }\n"
        record(code)
        record("if ready { run() }")
        XCTAssertEqual(store.counts().total, 2)
        XCTAssertTrue(store.getRecentItems().contains { $0.contentText == code })
    }

    func testSearchUsesLiteralPunctuationAndChinese() {
        record("进度 100% · file_name \\done")
        record("进度 100 · filename done")
        for query in ["%", "_", "\\", "FILE_NAME"] {
            XCTAssertEqual(store.getRecentItems(query: query).count, 1, query)
        }
        XCTAssertEqual(store.getRecentItems(query: "进度").count, 2)
        XCTAssertEqual(store.getRecentItems(query: "' OR 1=1 --").count, 0)
    }

    func testDuplicateMovesToFrontWithoutLosingPinOrID() throws {
        record("keep")
        let original = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: original.id)
        record("new")
        record("keep")
        let refreshed = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(store.counts().total, 2)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertTrue(refreshed.pinned)
        XCTAssertGreaterThan(refreshed.timestamp, original.timestamp)
    }

    func testRapidRecopiesAreAlwaysMostRecent() throws {
        record("first")
        let first = try XCTUnwrap(store.getRecentItems().first)
        for n in 0..<30 { record("quick copy \(n)") }
        record("first")
        XCTAssertEqual(store.getRecentItems().first?.id, first.id)
    }

    func testUnpinningOldClipKeepsItAvailableAtRetentionLimit() throws {
        record("old favorite")
        let favorite = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: favorite.id)
        for n in 0..<200 { record("recent \(n)") }
        store.setPinned(false, for: favorite.id)
        XCTAssertEqual(store.getRecentItems().first?.id, favorite.id)
        XCTAssertEqual(store.counts().total, 200)
    }

    func testVoiceDuplicateKeepsCurrentSessionAndStaysInVoiceFilter() throws {
        record("same output")
        let first = UUID(), second = UUID()
        store.recordVoiceOpsText(sessionID: first, text: "same output", selectedText: nil, voiceIntent: "polish", llmUsed: nil, appBundleID: nil)
        store.recordVoiceOpsText(sessionID: second, text: "same output", selectedText: "source", voiceIntent: "translate", llmUsed: "local", appBundleID: nil)
        XCTAssertEqual(store.counts().total, 2)
        XCTAssertEqual(store.getRecentItems(filter: .init(source: .voiceops)).count, 1)
        XCTAssertEqual(store.getItemsBySession(second).first?.selectedText, "source")
        XCTAssertTrue(store.getItemsBySession(first).isEmpty)
    }

    func testFiltersApplyBeforeLimitAndFindImageFilename() throws {
        store.recordSystemImage(Data([1, 2, 3]), appBundleID: nil, originalPath: "/tmp/设计稿_100%.png")
        for number in 0..<20 { record("text \(number)") }
        XCTAssertEqual(store.getRecentItems(limit: 1, filter: .init(type: .image), query: "设计稿_").count, 1)
        XCTAssertTrue(store.getRecentItems(filter: .init(type: .image), query: "text").isEmpty)
        XCTAssertEqual(store.getRecentItems(filter: .init(type: .text)).count, 20)
    }

    func testDeleteAndUndoImageKeepsStoredAndOriginalFiles() throws {
        let original = directory.appendingPathComponent("original.png")
        try Data([1]).write(to: original)
        store.recordSystemImage(Data([1, 2, 3]), appBundleID: nil, originalPath: original.path)
        let item = try XCTUnwrap(store.getRecentItems().first)
        let path = try XCTUnwrap(item.contentImagePath)
        XCTAssertEqual(store.deleteItems(ids: [item.id]), 1)
        XCTAssertTrue(store.getRecentItems().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(store.counts().undoable, 1)
        XCTAssertEqual(store.undoDeletion(), 1)
        XCTAssertEqual(store.getRecentItems().first?.id, item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCleanupPreservesPinnedAndUndoSurvivesReopen() throws {
        record("pinned")
        let pinned = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: pinned.id)
        record("one"); record("two")
        XCTAssertEqual(store.deleteItems(), 2)
        XCTAssertEqual(store.getRecentItems().map(\.id), [pinned.id])
        store = nil
        store = ClipboardStore(directory: directory)
        XCTAssertEqual(store.counts().undoable, 2)
        XCTAssertEqual(store.undoDeletion(), 2)
        XCTAssertEqual(store.counts().total, 3)
        XCTAssertEqual(store.counts().pinned, 1)
    }

    func testNextDeletionPurgesPreviousImagesButNeverOriginalFiles() throws {
        let original = directory.appendingPathComponent("original.png")
        try Data([1]).write(to: original)
        store.recordSystemImage(Data([1, 2]), appBundleID: nil, originalPath: original.path)
        let image = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(store.deleteItems(ids: [image.id]), 1)
        // No-op deletions preserve the undo batch.
        XCTAssertEqual(store.deleteItems(ids: [UUID()]), 0)
        XCTAssertEqual(store.counts().undoable, 1)
        record("next")
        XCTAssertEqual(store.deleteItems(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(image.contentImagePath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(store.undoDeletion(), 1)
        XCTAssertEqual(store.getRecentItems().first?.contentText, "next")
    }

    func testFailedDeletionRollsBackPreviousUndoBatch() throws {
        record("old")
        XCTAssertEqual(store.deleteItems(), 1)
        record("protected")
        _ = store.counts()
        try sql("CREATE TRIGGER prevent_delete BEFORE UPDATE OF deleted_at ON clipboard_items WHEN NEW.content_text = 'protected' BEGIN SELECT RAISE(ABORT, 'test'); END;")
        XCTAssertNil(store.deleteItems())
        XCTAssertEqual(store.counts().total, 1)
        XCTAssertEqual(store.counts().undoable, 1)
        try sql("DROP TRIGGER prevent_delete;")
        XCTAssertEqual(store.undoDeletion(), 1)
        XCTAssertEqual(store.counts().total, 2)
    }

    func testRetentionKeeps200OrdinaryPlusPinnedAndUndoableImage() throws {
        record("pinned")
        let pinned = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: pinned.id)
        store.recordSystemImage(Data([9, 8, 7]), appBundleID: nil)
        let image = try XCTUnwrap(store.getRecentItems(filter: .init(type: .image)).first)
        XCTAssertEqual(store.deleteItems(ids: [image.id]), 1)
        for n in 0..<215 { record("ordinary \(n)") }
        XCTAssertEqual(store.counts().total, 201)
        XCTAssertEqual(store.counts().pinned, 1)
        XCTAssertEqual(store.counts().undoable, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(image.contentImagePath)))
        XCTAssertEqual(store.undoDeletion(), 1)
        XCTAssertEqual(store.counts().total, 201)
        XCTAssertEqual(store.getRecentItems(filter: .init(type: .image)).first?.id, image.id)
    }

    func testLegacyDatabaseMigrationPreservesRecords() throws {
        record("legacy")
        _ = store.counts()
        store = nil
        try sql("ALTER TABLE clipboard_items DROP COLUMN deleted_at;")
        store = ClipboardStore(directory: directory)
        let item = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(item.contentText, "legacy")
        XCTAssertEqual(store.deleteItems(ids: [item.id]), 1)
        XCTAssertEqual(store.undoDeletion(), 1)
    }
}
