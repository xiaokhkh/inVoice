import AppKit

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
        func waitFor(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(false, "model did not settle")
        }
        try await waitFor { model.items.count == 3 }
        model.setQuery("alpha")
        model.setQuery("不存在")
        model.setQuery("中文")
        pb.setString("untouched", forType: .string)
        model.copySelected()
        try check(pb.string(forType: .string) == "untouched", "pending search must not copy a stale selection")
        try await waitFor { !model.isSearching && model.items.count == 1 }
        try check(model.items.first?.contentText == "中文 beta 100%", "latest query wins")
        model.copySelected()
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
        try check(!model.copyItem(image) && model.copiedID == nil && model.message?.contains("丢失") == true, "missing image must not claim copied")
        try check(pb.string(forType: .string) == "中文 beta 100%", "copy failure preserves clipboard")
        print("PASS: search race, copy feedback, delete/undo, filters, missing-image fallback; isolated clipboard and database")
    }
}
