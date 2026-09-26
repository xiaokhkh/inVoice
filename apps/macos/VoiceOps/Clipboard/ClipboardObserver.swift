import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardObserver {
    static let shared = ClipboardObserver(store: ClipboardStore.shared)

    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let captureEnabled: () -> Bool
    private var lastChangeCount: Int
    private var timer: Timer?
    private var ignoreUntil: Date?
    private var defaultsObserver: Any?
    private var captureTask: Task<Void, Never>?

    init(store: ClipboardStore, pasteboard: NSPasteboard = .general,
         captureEnabled: @escaping () -> Bool = {
             UserDefaults.standard.object(forKey: ClipboardCapturePolicy.enabledKey) as? Bool ?? true
         }) {
        self.store = store
        self.pasteboard = pasteboard
        self.captureEnabled = captureEnabled
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateCaptureTimer() }
            }
        }
        updateCaptureTimer()
    }

    private func updateCaptureTimer() {
        if !captureEnabled() {
            timer?.invalidate()
            timer = nil
            captureTask?.cancel()
            return
        }
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureTask?.cancel()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    func markInternalWrite(duration: TimeInterval = 0.6) {
        ignoreUntil = Date().addingTimeInterval(duration)
    }

    // Only one image snapshot can be in flight, including hashing and disk writes. If copying
    // outruns conversion, the next poll reads the latest pasteboard, without a queue of huge bitmaps.
    func poll() {
        guard timer != nil, captureTask == nil else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if let ignoreUntil, ignoreUntil > Date() { return }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard ClipboardCapturePolicy.shouldCapture(types: types, enabled: captureEnabled()) else { return }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let snapshot = readSnapshot()
        // A lazy pasteboard provider can change ownership during materialization.
        guard pasteboard.changeCount == changeCount else { return }
        let store = self.store
        captureTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { Self.prepare(snapshot) }.value
            if !Task.isCancelled, self?.captureEnabled() == true {
                await Task.detached(priority: .utility) {
                    switch prepared {
                    case .image(let data, let path): store.recordSystemImage(data, appBundleID: bundleID, originalPath: path)
                    case .text(let text): store.recordSystemText(text, appBundleID: bundleID)
                    case nil: break
                    }
                    store.waitForPendingWrites()
                }.value
            }
            self?.captureTask = nil
            // Catch the most recent copy immediately after a slow conversion completes.
            self?.poll()
        }
    }

    private struct Snapshot: Sendable {
        var image: ClipboardImageProcessor.Input?
        var originalPath: String?
        var text: String?
        var rtf: Data?
    }
    private enum Prepared: Sendable {
        case image(Data, String?)
        case text(String)
    }

    private func readSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        let imageTypes = [UTType.png.identifier, UTType.tiff.identifier, "public.webp", UTType.jpeg.identifier,
                          UTType.heic.identifier, UTType.heif.identifier, UTType.gif.identifier, UTType.bmp.identifier]
            + NSImage.imageTypes
        if let type = pasteboard.availableType(from: imageTypes.map { NSPasteboard.PasteboardType($0) }),
           let data = pasteboard.data(forType: type) {
            snapshot.image = .data(data)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = urls.first {
            snapshot.image = .file(url)
            snapshot.originalPath = url.path
        }
        snapshot.text = pasteboard.string(forType: .string)
        if snapshot.text == nil { snapshot.rtf = pasteboard.data(forType: .rtf) }
        return snapshot
    }

    private nonisolated static func prepare(_ snapshot: Snapshot) -> Prepared? {
        autoreleasepool {
            if let input = snapshot.image, let data = ClipboardImageProcessor.pngData(from: input) {
                return .image(data, snapshot.originalPath)
            }
            if let text = snapshot.text { return .text(text) }
            if let rtf = snapshot.rtf,
               let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                return .text(attributed.string)
            }
            return nil
        }
    }
}
