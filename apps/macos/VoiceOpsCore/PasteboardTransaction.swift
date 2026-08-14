import AppKit
import Foundation

@MainActor
final class PasteboardTransaction {
    struct PreparedPaste: Equatable, Sendable {
        let expectedChangeCount: Int
    }

    private struct ItemSnapshot {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private struct Snapshot {
        let items: [ItemSnapshot]
    }

    static let shared = PasteboardTransaction()

    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private var markInternalWrite: (TimeInterval) -> Void
    private var backup: Snapshot?
    private var hasBackup = false
    private var lastWrittenChangeCount: Int?
    private var restoreGeneration: UInt64 = 0
    private var deliverySlotInUse = false
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.75,
        markInternalWrite: @escaping (TimeInterval) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = max(0, restoreDelay)
        self.markInternalWrite = markInternalWrite
    }

    func setInternalWriteMarker(_ marker: @escaping (TimeInterval) -> Void) {
        markInternalWrite = marker
    }

    /// Serializes the write -> settle -> Cmd+V boundary across every
    /// FocusInjector using the shared transaction. Clipboard restoration is
    /// intentionally outside this slot and is protected by generation checks.
    func acquireDeliverySlot() async {
        if !deliverySlotInUse {
            deliverySlotInUse = true
            return
        }
        await withCheckedContinuation { continuation in
            deliveryWaiters.append(continuation)
        }
    }

    func releaseDeliverySlot() {
        guard deliverySlotInUse else { return }
        if deliveryWaiters.isEmpty {
            deliverySlotInUse = false
            return
        }
        let next = deliveryWaiters.removeFirst()
        next.resume()
    }

    /// Captures the user's clipboard and temporarily replaces it with text.
    /// A pending batch keeps the earliest un-restored backup unless the user
    /// has copied something newer since our previous write.
    func prepareTextForPaste(_ text: String) -> PreparedPaste? {
        if hasBackup {
            if let lastWrittenChangeCount,
               pasteboard.changeCount != lastWrittenChangeCount {
                backup = captureSnapshot()
            }
        } else {
            backup = captureSnapshot()
            hasBackup = true
        }

        guard writeText(text, internalWriteDuration: restoreDelay + 0.5) else {
            abandonRestoreKeepingCurrentClipboard()
            return nil
        }
        return PreparedPaste(expectedChangeCount: pasteboard.changeCount)
    }

    /// Ensures Cmd+V sees the transcript even when a clipboard manager or the
    /// user changed the pasteboard during the pre-paste settling delay. The
    /// newer clipboard value becomes the value restored after a successful
    /// paste.
    func reassertTextIfNeeded(
        _ text: String,
        prepared: PreparedPaste
    ) -> PreparedPaste? {
        guard pasteboard.changeCount != prepared.expectedChangeCount else {
            return prepared
        }

        backup = captureSnapshot()
        hasBackup = true
        guard writeText(text, internalWriteDuration: restoreDelay + 0.5) else {
            abandonRestoreKeepingCurrentClipboard()
            return nil
        }
        return PreparedPaste(expectedChangeCount: pasteboard.changeCount)
    }

    func copyOnly(_ text: String) -> Bool {
        abandonRestoreKeepingCurrentClipboard()
        return writeText(text, internalWriteDuration: 0.75)
    }

    func scheduleRestore(after prepared: PreparedPaste) {
        guard hasBackup else { return }

        restoreGeneration &+= 1
        let generation = restoreGeneration
        let expectedChangeCount = prepared.expectedChangeCount
        let delay = restoreDelay

        Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            self?.restoreIfUnchanged(
                expectedChangeCount: expectedChangeCount,
                generation: generation
            )
        }
    }

    func abandonRestoreKeepingCurrentClipboard() {
        restoreGeneration &+= 1
        backup = nil
        hasBackup = false
        lastWrittenChangeCount = nil
    }

    private func writeText(_ text: String, internalWriteDuration: TimeInterval) -> Bool {
        markInternalWrite(internalWriteDuration)
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(text, forType: .string)
        if didWrite {
            lastWrittenChangeCount = pasteboard.changeCount
        }
        return didWrite
    }

    private func captureSnapshot() -> Snapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems,
              !pasteboardItems.isEmpty else {
            return nil
        }

        let items = pasteboardItems.compactMap { item -> ItemSnapshot? in
            let values = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return values.isEmpty ? nil : ItemSnapshot(values: values)
        }
        return items.isEmpty ? nil : Snapshot(items: items)
    }

    private func restoreIfUnchanged(expectedChangeCount: Int, generation: UInt64) {
        guard hasBackup, generation == restoreGeneration else { return }

        guard pasteboard.changeCount == expectedChangeCount else {
            backup = nil
            hasBackup = false
            lastWrittenChangeCount = nil
            return
        }

        markInternalWrite(0.75)
        pasteboard.clearContents()
        if let backup {
            let objects = backup.items.map { snapshot -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in snapshot.values {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !objects.isEmpty {
                pasteboard.writeObjects(objects)
            }
        }

        restoreGeneration &+= 1
        backup = nil
        hasBackup = false
        lastWrittenChangeCount = nil
    }
}
