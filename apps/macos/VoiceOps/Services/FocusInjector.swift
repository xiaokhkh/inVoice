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

    /// Clipboard history images use the same delivery lock and destination checks as text.
    func deliverImage(_ data: Data, targetPID: pid_t?) async -> DeliveryResult {
        guard !data.isEmpty else { return DeliveryResult(status: .failedClipboardWrite) }
        await clipboard.acquireDeliverySlot()
        defer { clipboard.releaseDeliverySlot() }
        guard let prepared = clipboard.prepareImageForPaste(data) else {
            return DeliveryResult(status: .failedClipboardWrite)
        }
        guard accessibilityGranted() else { return DeliveryResult(status: .copiedNoPermission) }
        guard targetStillMatches(targetPID) else { return DeliveryResult(status: .copiedFocusChanged) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard targetStillMatches(targetPID) else { return DeliveryResult(status: .copiedFocusChanged) }
        guard clipboard.isUnchanged(since: prepared) else { return DeliveryResult(status: .copiedSessionSuperseded) }
        let vKeyCode = Self.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)
        return DeliveryResult(status: pasteEventPoster(vKeyCode) ? .inserted : .copiedEventFailure)
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

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}
