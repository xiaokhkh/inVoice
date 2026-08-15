import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImageIO

@MainActor
final class FocusInjector {
    enum DeliveryStatus: String, Sendable {
        case inserted
        case copiedFocusChanged
        case copiedNoPermission
        case copiedSessionSuperseded
        case copiedEventFailure
        case failedClipboardWrite

        var didPostPaste: Bool {
            self == .inserted
        }
    }

    struct DeliveryResult: Sendable {
        let status: DeliveryStatus
    }

    private let clipboard: PasteboardTransaction
    private let accessibilityGranted: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let pasteEventPoster: (CGKeyCode) -> Bool

    init(
        clipboard: PasteboardTransaction? = nil,
        accessibilityGranted: @escaping () -> Bool = { Permissions.hasAccessibility() },
        frontmostPID: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        pasteEventPoster: ((CGKeyCode) -> Bool)? = nil
    ) {
        if let clipboard {
            self.clipboard = clipboard
        } else {
            self.clipboard = PasteboardTransaction.shared
            PasteboardTransaction.shared.setInternalWriteMarker { duration in
                ClipboardObserver.shared.markInternalWrite(duration: duration)
            }
        }
        self.accessibilityGranted = accessibilityGranted
        self.frontmostPID = frontmostPID
        self.pasteEventPoster = pasteEventPoster ?? Self.postPasteEvent
    }

    /// Delivers one final transcript. Every failure after a successful
    /// pasteboard write becomes copy-only; this method never attempts AX text
    /// mutation or Unicode typing after Cmd+V may have been posted.
    func deliver(
        _ text: String,
        targetPID: pid_t?,
        restoreClipboard: Bool = true,
        sessionGuard: @escaping @MainActor () -> Bool = { true }
    ) async -> DeliveryResult {
        guard !text.isEmpty else {
            return DeliveryResult(status: .failedClipboardWrite)
        }

        await clipboard.acquireDeliverySlot()
        defer { clipboard.releaseDeliverySlot() }

        guard sessionGuard() else {
            return copyOnly(text, status: .copiedSessionSuperseded)
        }

        guard accessibilityGranted() else {
            trace("[inject] copied reason=no_permission")
            return copyOnly(text, status: .copiedNoPermission)
        }

        guard targetStillMatches(targetPID) else {
            trace(
                "[inject] copied reason=focus_changed expected=\(targetPID ?? -1) "
                    + "current=\(frontmostPID() ?? -1)"
            )
            return copyOnly(text, status: .copiedFocusChanged)
        }

        guard var prepared = clipboard.prepareTextForPaste(text) else {
            trace("[inject] failed reason=clipboard_write")
            return DeliveryResult(status: .failedClipboardWrite)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        guard sessionGuard() else {
            clipboard.abandonRestoreKeepingCurrentClipboard()
            trace("[inject] copied reason=session_superseded")
            return DeliveryResult(status: .copiedSessionSuperseded)
        }

        guard targetStillMatches(targetPID) else {
            clipboard.abandonRestoreKeepingCurrentClipboard()
            trace(
                "[inject] copied reason=focus_changed_before_post expected=\(targetPID ?? -1) "
                    + "current=\(frontmostPID() ?? -1)"
            )
            return DeliveryResult(status: .copiedFocusChanged)
        }

        guard let refreshed = clipboard.reassertTextIfNeeded(text, prepared: prepared) else {
            trace("[inject] failed reason=clipboard_reassert")
            return DeliveryResult(status: .failedClipboardWrite)
        }
        prepared = refreshed

        let vKeyCode = Self.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)
        guard pasteEventPoster(vKeyCode) else {
            clipboard.abandonRestoreKeepingCurrentClipboard()
            trace("[inject] copied reason=event_creation keycode=\(vKeyCode)")
            return DeliveryResult(status: .copiedEventFailure)
        }

        if restoreClipboard {
            clipboard.scheduleRestore(after: prepared)
        } else {
            clipboard.abandonRestoreKeepingCurrentClipboard()
        }

        trace(
            "[inject] delivered status=inserted target_pid=\(targetPID ?? -1) "
                + "keycode=\(vKeyCode) restore=\(restoreClipboard)"
        )
        return DeliveryResult(status: .inserted)
    }

    func injectImageData(
        _ data: Data,
        restoreClipboard: Bool = false,
        originalPath: String? = nil
    ) -> Bool {
        guard !data.isEmpty, accessibilityGranted() else { return false }

        let pasteboard = NSPasteboard.general
        let backup = restoreClipboard ? deepCopyItems(pasteboard.pasteboardItems ?? []) : []
        ClipboardObserver.shared.markInternalWrite(duration: 1.0)
        pasteboard.clearContents()

        if let originalPath {
            let url = URL(fileURLWithPath: originalPath)
            if FileManager.default.fileExists(atPath: url.path) {
                pasteboard.writeObjects([url as NSURL])
            }
        }

        var didSet = false
        if let image = decodedImage(from: data) {
            didSet = pasteboard.writeObjects([image])
            if let tiff = image.tiffRepresentation {
                _ = pasteboard.setData(tiff, forType: .tiff)
            }
            _ = pasteboard.setData(data, forType: .png)
        } else {
            didSet = pasteboard.setData(data, forType: .png)
        }
        guard didSet else { return false }

        let vKeyCode = Self.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)
        guard pasteEventPoster(vKeyCode) else { return false }

        if restoreClipboard {
            let expectedChangeCount = pasteboard.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                guard pasteboard.changeCount == expectedChangeCount else { return }
                ClipboardObserver.shared.markInternalWrite()
                pasteboard.clearContents()
                if !backup.isEmpty {
                    pasteboard.writeObjects(backup)
                }
            }
        }
        return true
    }

    private func targetStillMatches(_ targetPID: pid_t?) -> Bool {
        guard let targetPID, targetPID > 0 else { return false }
        return frontmostPID() == targetPID
    }

    private func copyOnly(_ text: String, status: DeliveryStatus) -> DeliveryResult {
        let didWrite = clipboard.copyOnly(text)
        return DeliveryResult(status: didWrite ? status : .failedClipboardWrite)
    }

    private static func postPasteEvent(vKeyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            return false
        }

        let descriptors = PasteShortcutPlan.events(vKeyCode: vKeyCode)
        var events: [CGEvent] = []
        for descriptor in descriptors {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: descriptor.keyCode,
                keyDown: descriptor.isKeyDown
            ) else {
                return false
            }
            event.flags = descriptor.usesCommand ? [.maskCommand] : []
            events.append(event)
        }

        guard events.count == 2 else { return false }
        for event in events {
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Finds the physical key that produces `character` on the active
    /// ASCII-capable layout. This keeps Cmd+V working on Dvorak, Colemak and
    /// other non-QWERTY layouts.
    private static func keyCode(forCharacter character: Character) -> CGKeyCode? {
        let inputSource: TISInputSource? = {
            if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue() {
                return source
            }
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }()
        guard let inputSource,
              let rawLayout = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(rawLayout)
            .takeUnretainedValue() as Data
        let target = String(character)

        return layoutData.withUnsafeBytes { rawBuffer -> CGKeyCode? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let layout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            let maxLength = 4
            var unicode = [UniChar](repeating: 0, count: maxLength)

            for candidate in 0..<128 {
                var deadKeyState: UInt32 = 0
                var actualLength = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(candidate),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    maxLength,
                    &actualLength,
                    &unicode
                )
                guard status == noErr, actualLength > 0 else { continue }
                if String(utf16CodeUnits: unicode, count: actualLength) == target {
                    return CGKeyCode(candidate)
                }
            }
            return nil
        }
    }

    private func deepCopyItems(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
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

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}

@MainActor
final class CodexSubmitService {
    enum Result: String, Equatable, Sendable {
        case submitted
        case ignoredDifferentApp
        case deniedAccessibility
        case eventCreationFailed
    }

    private let accessibilityGranted: () -> Bool
    private let frontmostBundleIdentifier: () -> String?
    private let returnEventPoster: () -> Bool

    init(
        accessibilityGranted: @escaping () -> Bool = {
            Permissions.hasAccessibility()
        },
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        returnEventPoster: (() -> Bool)? = nil
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.returnEventPoster = returnEventPoster ?? Self.postReturnEvent
    }

    func submitIfCodexFrontmost() -> Result {
        let bundleIdentifier = frontmostBundleIdentifier()
        let appName = bundleIdentifier ?? "unknown"
        guard CodexSubmitShortcutPlan.shouldSubmit(
            frontmostBundleIdentifier: bundleIdentifier
        ) else {
            trace("[codex_submit] ignored frontmost=\(appName)")
            return .ignoredDifferentApp
        }
        guard accessibilityGranted() else {
            trace("[codex_submit] denied reason=accessibility")
            return .deniedAccessibility
        }
        guard returnEventPoster() else {
            trace("[codex_submit] failed reason=event_creation")
            return .eventCreationFailed
        }

        trace("[codex_submit] delivered bundle=\(appName)")
        return .submitted
    }

    private static func postReturnEvent() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            return false
        }

        let descriptors = CodexSubmitShortcutPlan.events(
            returnKeyCode: UInt16(kVK_Return)
        )
        var events: [CGEvent] = []
        for descriptor in descriptors {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: descriptor.keyCode,
                keyDown: descriptor.isKeyDown
            ) else {
                return false
            }
            event.flags = []
            events.append(event)
        }

        guard events.count == 2 else { return false }
        for event in events {
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}
