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

    func testUnpinningOldClipKeepsItAvailableBeyondOldCountLimit() throws {
        record("old favorite")
        let favorite = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: favorite.id)
        for n in 0..<200 { record("recent \(n)") }
        store.setPinned(false, for: favorite.id)
        XCTAssertEqual(store.getRecentItems().first?.id, favorite.id)
        XCTAssertEqual(store.counts().total, 201)
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

    func testNoCountCapKeepsOrdinaryPinnedAndUndoableImage() throws {
        record("pinned")
        let pinned = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: pinned.id)
        store.recordSystemImage(Data([9, 8, 7]), appBundleID: nil)
        let image = try XCTUnwrap(store.getRecentItems(filter: .init(type: .image)).first)
        XCTAssertEqual(store.deleteItems(ids: [image.id]), 1)
        for n in 0..<515 { record("ordinary \(n)") }
        XCTAssertEqual(store.counts().total, 516)
        XCTAssertEqual(store.counts().pinned, 1)
        XCTAssertEqual(store.counts().undoable, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(image.contentImagePath)))
        XCTAssertEqual(store.undoDeletion(), 1)
        XCTAssertEqual(store.counts().total, 517)
        XCTAssertEqual(store.getRecentItems(filter: .init(type: .image)).first?.id, image.id)
    }

    func testLegacyDatabaseMigrationPreservesRecords() throws {
        record("legacy")
        _ = store.counts()
        store = nil
        try sql("DROP INDEX idx_clipboard_recent_active; DROP INDEX idx_clipboard_identity_active; DROP INDEX idx_clipboard_lru_active; DROP INDEX idx_clipboard_storage; DROP INDEX idx_clipboard_page;")
        try sql("ALTER TABLE clipboard_items DROP COLUMN deleted_at;")
        store = ClipboardStore(directory: directory)
        let item = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(item.contentText, "legacy")
        XCTAssertEqual(store.deleteItems(ids: [item.id]), 1)
        XCTAssertEqual(store.undoDeletion(), 1)
    }

    func testSuccessfulUseProtectsOldClipWithoutReorderingHistory() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        record("frequently reused")
        let original = try XCTUnwrap(store.getRecentItems().first)
        for n in 0..<2 { record("newer \(n)") }
        let before = store.getRecentItems().map(\.id)
        store.markUsed(original.id)
        XCTAssertEqual(store.getRecentItems().map(\.id), before)
        let used = try XCTUnwrap(store.getRecentItems().last)
        XCTAssertEqual(used.timestamp, original.timestamp)
        XCTAssertGreaterThan(used.lastUsedAt, original.lastUsedAt)
        record("overflow")
        let remaining = store.getRecentItems()
        XCTAssertEqual(remaining.count, 3)
        XCTAssertLessThanOrEqual(store.counts().ordinaryBytes, 800)
        XCTAssertTrue(remaining.contains { $0.id == original.id })
        XCTAssertFalse(remaining.contains { $0.contentText == "newer 0" })
    }

    func testPreviewDoesNotExtendRetentionAndUsageSurvivesRelaunch() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        record("preview only")
        let preview = try XCTUnwrap(store.getRecentItems().first)
        record("used")
        let used = try XCTUnwrap(store.getRecentItems().first)
        record("later")
        _ = store.getRecentItems(query: "preview only")
        store.markUsed(used.id)
        let usage = try XCTUnwrap(store.getRecentItems().first { $0.id == used.id }).lastUsedAt
        store = nil
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        XCTAssertEqual(store.getRecentItems().first { $0.id == used.id }?.lastUsedAt, usage)
        record("new capture")
        XCTAssertFalse(store.getRecentItems().contains { $0.id == preview.id })
        XCTAssertTrue(store.getRecentItems().contains { $0.id == used.id })
    }

    func testLRUMigrationInitializesUsageWithoutChangingDatesOrUndo() throws {
        record("old record")
        let original = try XCTUnwrap(store.getRecentItems().first)
        record("undo me")
        let deleted = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(store.deleteItems(ids: [deleted.id]), 1)
        store = nil
        try sql("DROP INDEX idx_clipboard_usage; DROP INDEX idx_clipboard_lru_active; ALTER TABLE clipboard_items DROP COLUMN last_used_at;")
        store = ClipboardStore(directory: directory)
        let restored = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(restored.timestamp, original.timestamp)
        XCTAssertEqual(restored.lastUsedAt, original.timestamp)
        XCTAssertEqual(store.counts().undoable, 1)
        store.markUsed(deleted.id) // A stale UI action must not revive a deleted record.
        XCTAssertEqual(store.counts().total, 1)
        XCTAssertEqual(store.undoDeletion(), 1)
        let undone = try XCTUnwrap(store.getRecentItems().first { $0.id == deleted.id })
        XCTAssertGreaterThan(undone.lastUsedAt, deleted.lastUsedAt)
    }
    func testCapacityEvictsImageByLRUWhileProtectingPinsUndoAndOriginals() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        store.recordSystemImage(Data(repeating: 1, count: 100), appBundleID: nil)
        let pinned = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: pinned.id)
        store.recordSystemImage(Data(repeating: 2, count: 100), appBundleID: nil)
        let undo = try XCTUnwrap(store.getRecentItems().last)
        XCTAssertEqual(store.deleteItems(ids: [undo.id]), 1)
        let original = directory.appendingPathComponent("original.png")
        try Data([42]).write(to: original)
        store.recordSystemImage(Data(repeating: 3, count: 100), appBundleID: nil, originalPath: original.path)
        let victim = try XCTUnwrap(store.getRecentItems().last)
        store.recordSystemImage(Data(repeating: 4, count: 100), appBundleID: nil)
        store.recordSystemImage(Data(repeating: 5, count: 100), appBundleID: nil)
        let counts = store.counts()
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.ordinaryBytes, 712)
        XCTAssertEqual(counts.pinnedBytes, 356)
        XCTAssertEqual(counts.undoBytes, 356)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(victim.contentImagePath)))
        for item in [pinned, undo] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.contentImagePath)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testOversizeCapturePreservesExistingHistoryAndDoesNotWriteImage() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        record("keep")
        let before = store.getRecentItems().map(\.id)
        store.recordSystemImage(Data(repeating: 9, count: 801), appBundleID: nil)
        XCTAssertEqual(store.getRecentItems().map(\.id), before)
        XCTAssertNotNil(store.counts().warning)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("clipboard_images").path).isEmpty)
        record(String(repeating: "中", count: 300))
        XCTAssertEqual(store.getRecentItems().map(\.id), before)
        record("new valid capture")
        XCTAssertEqual(store.counts().total, 2)
        XCTAssertNil(store.counts().warning)
    }

    func testVoiceDuplicateAccountsForUTF8AndUpdatedContext() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        let session = UUID()
        store.recordVoiceOpsText(sessionID: session, text: "你好", selectedText: "文", voiceIntent: nil, llmUsed: nil, appBundleID: nil)
        let original = try XCTUnwrap(store.getRecentItems().first)
        XCTAssertEqual(store.counts().ordinaryBytes, 265)
        record("other")
        // Updated context makes this duplicate cost 662 bytes, so the other clip must be evicted.
        store.recordVoiceOpsText(sessionID: session, text: "你好", selectedText: String(repeating: "x", count: 400), voiceIntent: nil, llmUsed: nil, appBundleID: nil)
        XCTAssertEqual(store.counts().ordinaryBytes, 662)
        XCTAssertEqual(store.getRecentItems().map(\.id), [original.id])
        // A rejected oversized duplicate must leave the earlier context intact.
        store.recordVoiceOpsText(sessionID: session, text: "你好", selectedText: String(repeating: "x", count: 800), voiceIntent: nil, llmUsed: nil, appBundleID: nil)
        XCTAssertEqual(store.counts().ordinaryBytes, 662)
        XCTAssertEqual(store.getRecentItems().first?.selectedText?.count, 400)
        XCTAssertNotNil(store.counts().warning)
    }

    func testCapacityDeletionRollbackKeepsEveryImage() throws {
        store = ClipboardStore(directory: directory, capacityBytes: 800)
        for byte in UInt8(1)...2 { store.recordSystemImage(Data(repeating: byte, count: 100), appBundleID: nil) }
        let before = store.getRecentItems()
        // New image needs both older clips removed. Failure on the second victim rolls back both.
        try sql("CREATE TRIGGER fail_eviction BEFORE DELETE ON clipboard_items WHEN OLD.id = '\(before[0].id.uuidString)' BEGIN SELECT RAISE(ABORT, 'test'); END;")
        store.recordSystemImage(Data(repeating: 3, count: 500), appBundleID: nil)
        XCTAssertEqual(store.counts().total, 3)
        for item in before {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.contentImagePath)))
        }
        try sql("DROP TRIGGER fail_eviction;")
        record("retry")
        XCTAssertLessThanOrEqual(store.counts().ordinaryBytes, 800)
    }

    func testStorageMigrationRecountsWithoutEvictingOrChangingRecords() throws {
        record("中文")
        let original = try XCTUnwrap(store.getRecentItems().first)
        store.setPinned(true, for: original.id)
        store.recordSystemImage(Data(repeating: 1, count: 100), appBundleID: nil)
        let image = try XCTUnwrap(store.getRecentItems().last)
        XCTAssertEqual(store.deleteItems(ids: [image.id]), 1)
        record("retained on upgrade")
        let before = store.getRecentItems()
        store = nil
        try sql("DROP INDEX idx_clipboard_storage; ALTER TABLE clipboard_items DROP COLUMN storage_bytes;")
        // A lower new budget must not delete anything merely by opening the database.
        store = ClipboardStore(directory: directory, capacityBytes: 1)
        XCTAssertEqual(store.getRecentItems().map(\.id), before.map(\.id))
        XCTAssertEqual(store.getRecentItems().map(\.timestamp), before.map(\.timestamp))
        XCTAssertEqual(store.getRecentItems().map(\.contentHash), before.map(\.contentHash))
        XCTAssertEqual(store.counts().pinnedBytes, 262)
        XCTAssertEqual(store.counts().undoBytes, 356)
        XCTAssertEqual(store.counts().ordinaryBytes, 275)
        store.setPinned(false, for: original.id)
        XCTAssertEqual(store.counts().pinned, 1)
        XCTAssertEqual(store.getRecentItems().map(\.id), before.map(\.id))
        XCTAssertNotNil(store.counts().warning)
    }

    func testPaginationFiltersEntireHistoryAndHasStableBoundaries() throws {
        for n in 0..<350 { record("page \(n)") }
        let all = store.getRecentItems()
        store.setPinned(true, for: all.last!.id)
        let expected = store.getRecentItems().map(\.id)
        var actual: [UUID] = []
        for offset in stride(from: 0, to: 400, by: 100) {
            actual += store.getRecentItems(limit: 100, offset: offset).map(\.id)
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, 350)
        XCTAssertEqual(store.getRecentItems(limit: 1, query: "page 1", offset: 10).first?.id,
                       store.getRecentItems(query: "page 1")[10].id)
        XCTAssertEqual(store.getRecentItems(limit: 100, filter: .init(pinnedOnly: true)).count, 1)
    }

}
