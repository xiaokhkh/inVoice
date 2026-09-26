import AppKit

private actor ImageReadGate {
    private var pending: CheckedContinuation<Data?, Never>?
    var waiting: Bool { pending != nil }
    func read() async -> Data? { await withCheckedContinuation { pending = $0 } }
    func finish() { pending?.resume(returning: Data([137, 80, 78, 71])); pending = nil }
}

@main
struct ClipboardExperienceSmoke {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inVoice-model-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let pb = NSPasteboard(name: .init("inVoice.model-tests.\(UUID())"))
        defer { pb.clearContents(); pb.releaseGlobally() }
        store.recordSystemText("  alpha\n    indented\n", appBundleID: nil)
        store.recordSystemText("中文 beta 100%", appBundleID: nil)
        store.recordSystemImage(Data([1, 2, 3]), appBundleID: nil, originalPath: "/tmp/image.png")
        _ = store.counts()
        let model = ClipboardHistoryViewModel(store: store, pasteboard: pb)
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ClipboardExperienceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ predicate: @MainActor () async -> Bool) async throws {
            for _ in 0..<200 {
                if await predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(false, "model did not settle")
        }
        try await waitFor { model.items.count == 3 }
        model.setQuery("alpha")
        model.setQuery("不存在")
        model.setQuery("中文")
        pb.setString("untouched", forType: .string)
        if let selected = model.selectedItem() { _ = await model.copyItem(selected) }
        try check(pb.string(forType: .string) == "untouched", "pending search must not copy a stale selection")
        try await waitFor { !model.isSearching && model.items.count == 1 }
        try check(model.items.first?.contentText == "中文 beta 100%", "latest query wins")
        if let selected = model.selectedItem() { _ = await model.copyItem(selected) }
        try check(pb.string(forType: .string) == "中文 beta 100%" && model.copiedID == model.items.first?.id, "copy success feedback")
        model.deleteSelected()
        try await waitFor { !model.isBusy && model.items.isEmpty && model.counts.undoable == 1 }
        model.undoDeletion()
        try await waitFor { !model.isBusy && !model.isSearching && model.items.count == 3 && model.counts.undoable == 0 }
        try check(model.query.isEmpty && model.category == .all, "undo clears filters and restores records")
        model.setCategory(.image)
        try await waitFor { !model.isSearching && model.items.count == 1 }
        let image = model.items[0]
        try FileManager.default.removeItem(atPath: image.contentImagePath!)
        try check(!(await model.copyItem(image)) && model.copiedID == nil && model.message?.contains("丢失") == true, "missing image must not claim copied")
        try check(pb.string(forType: .string) == "中文 beta 100%", "copy failure preserves clipboard")
        let usageBeforeFailure = store.getRecentItems(filter: .init(type: .image))[0].lastUsedAt
        try check(usageBeforeFailure == image.lastUsedAt, "failed copy does not extend retention")

        let gate = ImageReadGate()
        let slow = ClipboardHistoryViewModel(store: store, pasteboard: pb, isActive: false,
                                            loadImage: { _ in await gate.read() })
        let copying = Task { await slow.copyItem(image) }
        try await waitFor { await gate.waiting }
        try check(slow.isTransferring, "async loading exposes busy feedback without blocking the main actor")
        pb.clearContents(); pb.setString("new external copy", forType: .string)
        await gate.finish()
        try check(!(await copying.value) && pb.string(forType: .string) == "new external copy", "async image copy must not overwrite a newer clipboard")
        try check(store.getRecentItems(filter: .init(type: .image))[0].lastUsedAt == usageBeforeFailure, "superseded copy is not LRU use")

        let cancelled = Task { await slow.copyItem(image) }
        try await waitFor { await gate.waiting }
        cancelled.cancel()
        await gate.finish()
        try check(!(await cancelled.value) && pb.string(forType: .string) == "new external copy", "cancelled copy preserves clipboard")
        let copied = Task { await slow.copyItem(image) }
        try await waitFor { await gate.waiting }
        await gate.finish()
        try check(await copied.value, "async image copy succeeds")
        let used = store.getRecentItems(filter: .init(type: .image))[0]
        try check(used.lastUsedAt > usageBeforeFailure && used.timestamp == image.timestamp, "successful image copy updates LRU without reordering")

        let fallback = ClipboardHistoryViewModel(store: store,
            injector: FocusInjector(clipboard: PasteboardTransaction(pasteboard: pb),
                                    accessibilityGranted: { false }, frontmostPID: { 100 },
                                    pasteEventPoster: { _ in fatalError("must not send input") }),
            pasteboard: pb, isActive: false, loadImage: { _ in Data([137, 80, 78, 71]) })
        try check(!(await fallback.pasteItem(image, targetPID: 100)), "no permission returns copy-only guidance")
        try check(store.getRecentItems(filter: .init(type: .image))[0].lastUsedAt > used.lastUsedAt, "successful copy-only fallback counts as use")
        try check(slow.items.isEmpty, "hidden panel ignores database changes")
        slow.setActive(true)
        try await waitFor { slow.items.count == store.counts().total }
        slow.setActive(false)
        let oldCount = slow.items.count
        store.recordSystemText("captured while hidden", appBundleID: nil)
        _ = store.counts()
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(slow.items.count == oldCount, "hidden panel stays dormant")
        slow.setActive(true)
        try await waitFor { slow.items.count == oldCount + 1 }
        print("PASS: search, copy, delete/undo, missing images, async clipboard race, cancellation, LRU success/failure, copy-only fallback, hidden-panel refresh")
    }
}
