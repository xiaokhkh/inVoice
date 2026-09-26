import AppKit
import Foundation

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    enum Category: String, CaseIterable, Identifiable {
        case all, pinned, text, image, voice
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "全部"
            case .pinned: return "已固定"
            case .text: return "文字"
            case .image: return "图片"
            case .voice: return "语音"
            }
        }
        var filter: ClipboardStore.Filter {
            switch self {
            case .all: return .init()
            case .pinned: return .init(pinnedOnly: true)
            case .text: return .init(type: .text)
            case .image: return .init(type: .image)
            case .voice: return .init(source: .voiceops)
            }
        }
    }

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var query = ""
    @Published private(set) var category: Category = .all
    @Published private(set) var counts = ClipboardStore.Counts()
    @Published private(set) var message: String?
    @Published private(set) var copiedID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var isSearching = false

    private let store: ClipboardStore
    private let injector: FocusInjector
    private let pasteboard: NSPasteboard
    private var observer: Any?
    private var refreshGeneration = 0
    private var searchWorkItem: DispatchWorkItem?
    private var feedbackWorkItem: DispatchWorkItem?
    private var appNames: [String: String] = [:]
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(store: ClipboardStore = .shared, injector: FocusInjector? = nil, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        self.injector = injector ?? FocusInjector()
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(resetSelection: false) }
        }
        refresh(resetSelection: true)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        searchWorkItem?.cancel()
        feedbackWorkItem?.cancel()
    }

    func refresh(resetSelection: Bool) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let selectionID = selectedItem()?.id
        let previousIndex = selectedIndex
        let query = self.query
        let filter = category.filter
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let items = store.getRecentItems(filter: filter, query: query)
            let counts = store.counts()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.items = items
                self.isSearching = false
                self.counts = counts
                self.selectedIndex = resetSelection ? 0 : (items.firstIndex { $0.id == selectionID } ?? min(previousIndex, max(0, items.count - 1)))
            }
        }
    }

    func setQuery(_ value: String) {
        guard value != query else { return }
        query = value
        isSearching = true
        refreshGeneration &+= 1
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(resetSelection: true) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func setCategory(_ value: Category) {
        guard category != value else { return }
        category = value
        isSearching = true
        searchWorkItem?.cancel()
        refresh(resetSelection: true)
    }

    func clearQuery() { setQuery("") }
    func resetFilters() { clearQuery(); setCategory(.all) }

    func moveSelection(delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    func selectIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func selectID(_ id: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    func selectedItem() -> ClipboardItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func copySelected() {
        if let item = selectedItem() { copyItem(item) }
    }

    func deleteSelected() {
        if let item = selectedItem() { deleteItem(item) }
    }

    func deleteItem(_ item: ClipboardItem) {
        mutate({ $0.deleteItems(ids: [item.id]) }, success: { "已删除 \($0) 条记录，可撤销" })
    }

    func clearUnpinned() {
        mutate({ $0.deleteItems() }, success: { "已清理 \($0) 条记录，固定内容已保留" })
    }

    func undoDeletion() {
        guard !isBusy, !isSearching else { return }
        mutate({ $0.undoDeletion() }, success: { "已恢复 \($0) 条记录" })
        resetFilters()
    }

    private func mutate(_ operation: @escaping @Sendable (ClipboardStore) -> Int?, success: @escaping (Int) -> String) {
        guard !isBusy, !isSearching else { return }
        isBusy = true
        let store = self.store
        Task {
            let count = await Task.detached(priority: .userInitiated) { operation(store) }.value
            isBusy = false
            showMessage(count.map(success) ?? "操作未完成，请重试。原记录已保留。")
            refresh(resetSelection: false)
        }
    }

    func togglePinned(_ item: ClipboardItem) {
        guard !isSearching else { return }
        store.setPinned(!item.pinned, for: item.id)
    }

    @discardableResult
    func copyItem(_ item: ClipboardItem) -> Bool {
        guard !isSearching else { showMessage("正在搜索，请稍候"); return false }
        let pb = pasteboard
        let didWrite: Bool
        switch item.type {
        case .text:
            guard let text = item.contentText, !text.isEmpty else {
                showMessage("这条记录没有可复制的文字")
                return false
            }
            ClipboardObserver.shared.markInternalWrite()
            pb.clearContents()
            didWrite = pb.setString(text, forType: .string)
        case .image:
            guard let data = imageData(for: item) else {
                showMessage("图片文件已丢失，无法复制")
                return false
            }
            ClipboardObserver.shared.markInternalWrite()
            pb.clearContents()
            // One image representation avoids pasting both a file and an image in rich editors.
            didWrite = pb.setData(data, forType: .png)
        }
        showMessage(didWrite ? "已复制，可到其他应用粘贴" : "复制失败，请重试", copied: didWrite ? item.id : nil)
        return didWrite
    }

    /// The panel captures its destination when opened. A changed destination becomes copy-only.
    func pasteItem(_ item: ClipboardItem, targetPID: pid_t?) async -> Bool {
        guard !isSearching else { showMessage("正在搜索，请稍候"); return false }
        let result: FocusInjector.DeliveryResult
        switch item.type {
        case .text:
            guard let text = item.contentText else { return false }
            result = await injector.deliver(text, targetPID: targetPID, restoreClipboard: false)
        case .image:
            guard let data = imageData(for: item) else {
                showMessage("图片文件已丢失，无法粘贴")
                return false
            }
            result = await injector.deliverImage(data, targetPID: targetPID)
        }
        if result.status == .inserted { return true }
        switch result.status {
        case .failedClipboardWrite: showMessage("复制失败，请重试")
        case .copiedSessionSuperseded: showMessage("剪贴板内容已变化，请重新选择记录粘贴")
        default: showMessage("已复制。请回到目标应用按 ⌘V 粘贴。")
        }
        return false
    }

    func showMessage(_ text: String, copied: UUID? = nil) {
        feedbackWorkItem?.cancel()
        message = text
        copiedID = copied
        let work = DispatchWorkItem { [weak self] in self?.message = nil; self?.copiedID = nil }
        feedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func sourceName(for item: ClipboardItem) -> String {
        if item.source == .voiceops { return "inVoice 语音" }
        guard let bundle = item.appBundleID else { return "系统剪贴板" }
        if let cached = appNames[bundle] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "系统剪贴板"
        appNames[bundle] = name
        return name
    }

    func metaText(for item: ClipboardItem) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp) / 1000)
        let age = Date().timeIntervalSince(date)
        let time = age < 60 ? "刚刚" : relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(sourceName(for: item)) · \(time)"
    }

    func revealImage(_ item: ClipboardItem) {
        for path in [item.contentOriginalPath, item.contentImagePath].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
        }
        showMessage("图片文件已丢失，无法在访达中显示")
    }

    private func imageData(for item: ClipboardItem) -> Data? {
        guard let path = item.contentImagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return data
    }
}
