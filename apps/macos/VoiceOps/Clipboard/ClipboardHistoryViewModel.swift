import AppKit
import Foundation

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var query: String = ""

    private let store: ClipboardStore
    private let injector: FocusInjector
    private var observer: Any?
    private let maxItems = 200
    private var imageMetaCache: [UUID: String] = [:]

    init(store: ClipboardStore = .shared, injector: FocusInjector? = nil) {
        self.store = store
        self.injector = injector ?? FocusInjector()
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(resetSelection: false)
            }
        }
        refresh(resetSelection: true)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh(resetSelection: Bool) {
        let query = self.query
        let store = self.store
        let maxItems = self.maxItems
        DispatchQueue.global(qos: .userInitiated).async {
            let items: [ClipboardItem]
            if query.isEmpty {
                items = store.getRecentItems(limit: maxItems)
            } else {
                items = store.searchText(query, limit: maxItems)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.items = items
                if resetSelection || self.selectedIndex >= items.count {
                    self.selectedIndex = items.isEmpty ? 0 : 0
                }
                let ids = Set(items.map { $0.id })
                self.imageMetaCache = self.imageMetaCache.filter { ids.contains($0.key) }
            }
        }
    }

    func setQuery(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .newlines)
        if trimmed == query { return }
        query = trimmed
        refresh(resetSelection: true)
    }

    func appendQuery(_ value: String) {
        let next = query + value
        setQuery(next)
    }

    func deleteQueryBackward() {
        guard !query.isEmpty else { return }
        query.removeLast()
        refresh(resetSelection: true)
    }

    func clearQuery() {
        setQuery("")
    }

    func moveSelection(delta: Int) {
        guard !items.isEmpty else { return }
        var next = selectedIndex + delta
        if next < 0 { next = 0 }
        if next >= items.count { next = items.count - 1 }
        selectedIndex = next
    }

    func selectIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func selectedItem() -> ClipboardItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func copySelected() {
        guard let item = selectedItem() else { return }
        copyItem(item)
    }

    func injectSelected() {
        guard let item = selectedItem() else { return }
        injectItem(item)
    }

    func activateSelected() {
        guard let item = selectedItem() else { return }
        activateItem(item)
    }

    func deleteSelected() {
        guard let item = selectedItem() else { return }
        deleteItem(item)
    }

    func deleteItem(_ item: ClipboardItem) {
        store.deleteItem(id: item.id)
    }

    func togglePinned(_ item: ClipboardItem) {
        store.setPinned(!item.pinned, for: item.id)
    }

    func copyItem(_ item: ClipboardItem) {
        switch item.type {
        case .text:
            guard let text = item.contentText, !text.isEmpty else { return }
            ClipboardObserver.shared.markInternalWrite()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .image:
            guard let imageData = loadImageData(for: item) else { return }
            ClipboardObserver.shared.markInternalWrite()
            let pb = NSPasteboard.general
            pb.clearContents()
            if let original = validFileURL(for: item) {
                pb.writeObjects([original as NSURL])
            }
            if let image = decodedImage(from: imageData) {
                pb.writeObjects([image])
                if let tiff = image.tiffRepresentation {
                    _ = pb.setData(tiff, forType: .tiff)
                }
                _ = pb.setData(imageData, forType: .png)
            } else {
                pb.setData(imageData, forType: .png)
            }
        }
    }

    func injectItem(_ item: ClipboardItem) {
        switch item.type {
        case .text:
            guard let text = item.contentText, !text.isEmpty else { return }
            let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Task { @MainActor [weak injector] in
                _ = await injector?.deliver(
                    text,
                    targetPID: targetPID,
                    restoreClipboard: false
                )
            }
        case .image:
            guard let imageData = loadImageData(for: item) else { return }
            _ = injector.injectImageData(
                imageData,
                restoreClipboard: false,
                originalPath: item.contentOriginalPath
            )
        }
    }

    func activateItem(_ item: ClipboardItem) {
        switch item.type {
        case .text:
            injectItem(item)
        case .image:
            if revealImageInFinder(item) {
                return
            }
            injectItem(item)
        }
    }

    func metaText(for item: ClipboardItem) -> String {
        let source = item.source == .voiceops ? "inVoice" : "System"
        let time = relativeTimeString(timestampMs: item.timestamp)
        if item.type == .image, let meta = imageMeta(for: item) {
            return "\(source) · \(time) · \(meta)"
        }
        return "\(source) · \(time)"
    }

    private func relativeTimeString(timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadImageData(for item: ClipboardItem) -> Data? {
        guard let path = item.contentImagePath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func validFileURL(for item: ClipboardItem) -> URL? {
        guard let path = item.contentOriginalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func decodedImage(from data: Data) -> NSImage? {
        if let image = NSImage(data: data) {
            return image
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSImage(cgImage: cgImage, size: .zero)
        }
        return nil
    }

    func previewImage(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image else { return nil }
        if let path = item.contentImagePath, let image = NSImage(contentsOfFile: path) {
            return image
        }
        if let path = item.contentOriginalPath, let image = NSImage(contentsOfFile: path) {
            return image
        }
        guard let data = loadImageData(for: item) else { return nil }
        return decodedImage(from: data)
    }

    private func revealImageInFinder(_ item: ClipboardItem) -> Bool {
        if let url = existingFileURL(item.contentOriginalPath) ?? existingFileURL(item.contentImagePath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
        guard let data = loadImageData(for: item) else { return false }
        do {
            let dir = try ensurePreviewDirectory()
            let fileURL = dir.appendingPathComponent("clipboard_\(UUID().uuidString).png")
            try data.write(to: fileURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return true
        } catch {
            return false
        }
    }

    private func existingFileURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func ensurePreviewDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("VoiceOps/ClipboardImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func imageMeta(for item: ClipboardItem) -> String? {
        if let cached = imageMetaCache[item.id] {
            return cached
        }
        guard let path = item.contentImagePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let ext = url.pathExtension.isEmpty ? "IMG" : url.pathExtension.uppercased()
        let meta = "\(ext) · \(width)x\(height)"
        imageMetaCache[item.id] = meta
        return meta
    }
}
