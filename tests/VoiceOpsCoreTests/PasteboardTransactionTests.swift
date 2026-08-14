import AppKit
import XCTest
@testable import VoiceOpsCore

@MainActor
final class PasteboardTransactionTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("voiceops.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    func testRestorePreservesAllPasteboardTypes() async throws {
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([1, 2, 3]), forType: .init("com.voiceops.test-data"))
        pasteboard.writeObjects([original])

        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            restoreDelay: 0.01
        )
        let prepared = try XCTUnwrap(transaction.prepareTextForPaste("transcript"))
        transaction.scheduleRestore(after: prepared)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(
            pasteboard.data(forType: .init("com.voiceops.test-data")),
            Data([1, 2, 3])
        )
    }

    func testExternalClipboardChangeSkipsRestore() async throws {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            restoreDelay: 0.01
        )
        let prepared = try XCTUnwrap(transaction.prepareTextForPaste("transcript"))
        transaction.scheduleRestore(after: prepared)

        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
    }

    func testConsecutivePastesRestoreClipboardFromBeforeBatch() async throws {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            restoreDelay: 0.02
        )

        let first = try XCTUnwrap(transaction.prepareTextForPaste("first"))
        transaction.scheduleRestore(after: first)
        let second = try XCTUnwrap(transaction.prepareTextForPaste("second"))
        transaction.scheduleRestore(after: second)
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyOnlyCancelsPendingRestore() async throws {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            restoreDelay: 0.01
        )
        let prepared = try XCTUnwrap(transaction.prepareTextForPaste("inserted"))
        transaction.scheduleRestore(after: prepared)

        XCTAssertTrue(transaction.copyOnly("manual fallback"))
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "manual fallback")
    }

    func testDeliverySlotSerializesPrePasteOperations() async {
        let transaction = PasteboardTransaction(
            pasteboard: pasteboard,
            restoreDelay: 0
        )
        await transaction.acquireDeliverySlot()

        var secondAcquired = false
        let second = Task { @MainActor in
            await transaction.acquireDeliverySlot()
            secondAcquired = true
            transaction.releaseDeliverySlot()
        }
        await Task.yield()
        XCTAssertFalse(secondAcquired)

        transaction.releaseDeliverySlot()
        await second.value
        XCTAssertTrue(secondAcquired)
    }
}
