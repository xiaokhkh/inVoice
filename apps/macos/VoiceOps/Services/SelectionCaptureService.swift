import AppKit
import ApplicationServices
import Foundation

enum SelectionCaptureMode {
    case auto
    case axOnly
    case copyFallback
}

enum SelectionCaptureSource: String {
    case accessibilitySelectedText
    case accessibilityRange
    case copyFallback
}

enum SelectionCaptureEmptyReason: String {
    case noSelection
    case nonTextSelection
    case clipboardUnchanged
}

enum SelectionCaptureFailure: String {
    case accessibilityDenied
    case eventSourceFailed
    case copyEventFailed
}

enum SelectionCaptureResult: Equatable {
    case success(text: String, source: SelectionCaptureSource)
    case empty(SelectionCaptureEmptyReason)
    case failure(SelectionCaptureFailure)

    var text: String? {
        if case .success(let text, _) = self {
            return text
        }
        return nil
    }

    var userMessage: String {
        switch self {
        case .success:
            return ""
        case .empty(.noSelection):
            return "没有选中文字。"
        case .empty(.nonTextSelection):
            return "选中的内容不包含文字。"
        case .empty(.clipboardUnchanged):
            return "未能读取选中的文字。"
        case .failure(.accessibilityDenied):
            return "请在设置中允许辅助功能，以读取选中文字。"
        case .failure(.eventSourceFailed):
            return "暂时无法读取输入事件，请重试。"
        case .failure(.copyEventFailed):
            return "未能复制选中文字，请重试。"
        }
    }
}

actor SelectionCaptureService {
    static let shared = SelectionCaptureService()

    private let copyPollIterations = 12
    private let copyPollDelayNs: UInt64 = 25_000_000
    private let restoreDelay: TimeInterval = 0.12

    func captureSelection(mode: SelectionCaptureMode = .auto) async -> SelectionCaptureResult {
        let start = CFAbsoluteTimeGetCurrent()
        guard Permissions.hasAccessibility() else {
            log(result: .failure(.accessibilityDenied), elapsedMs: elapsedMs(since: start))
            return .failure(.accessibilityDenied)
        }

        if let text = captureSelectedTextAttribute(), !text.isEmpty {
            let result: SelectionCaptureResult = .success(text: text, source: .accessibilitySelectedText)
            log(result: result, elapsedMs: elapsedMs(since: start))
            return result
        }

        if let text = captureSelectedTextRange(), !text.isEmpty {
            let result: SelectionCaptureResult = .success(text: text, source: .accessibilityRange)
            log(result: result, elapsedMs: elapsedMs(since: start))
            return result
        }

        if mode == .axOnly {
            let result: SelectionCaptureResult = .empty(.noSelection)
            log(result: result, elapsedMs: elapsedMs(since: start))
            return result
        }

        let result = await captureViaCopyFallback(mode: mode)
        log(result: result, elapsedMs: elapsedMs(since: start))
        return result
    }

    private func captureSelectedTextAttribute() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusStatus == .success, let focused else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        let element = focused as! AXUIElement
        var selectedObj: AnyObject?
        let selectedStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObj
        )
        guard selectedStatus == .success, let selected = selectedObj as? String else { return nil }
        return selected
    }

    private func captureSelectedTextRange() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusStatus == .success, let focused else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var valueObj: AnyObject?
        let valueStatus = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObj
        )
        guard valueStatus == .success, let value = valueObj as? String else { return nil }

        var rangeObj: AnyObject?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObj
        )
        guard rangeStatus == .success, let rangeObj else { return nil }
        guard CFGetTypeID(rangeObj) == AXValueGetTypeID() else { return nil }

        let axValue = rangeObj as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }
        guard cfRange.length > 0 else { return nil }

        let nsValue = value as NSString
        let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
        return nsValue.substring(with: nsRange)
    }

    private func captureViaCopyFallback(mode: SelectionCaptureMode) async -> SelectionCaptureResult {
        if mode == .copyFallback || mode == .auto {
            let pb = NSPasteboard.general
            let backup = snapshotPasteboard(pb)
            let initialChangeCount = pb.changeCount

            await ClipboardObserver.shared.markInternalWrite(duration: 1.2)
            guard postCopyEvent() else {
                return .failure(.copyEventFailed)
            }

            var capturedText: String?
            var didChange = false
            for _ in 0..<copyPollIterations {
                try? await Task.sleep(nanoseconds: copyPollDelayNs)
                if pb.changeCount != initialChangeCount {
                    didChange = true
                    if let text = readPasteboardText(pb), !text.isEmpty {
                        capturedText = text
                        break
                    }
                }
            }

            if didChange || !backup.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
                    restorePasteboard(pb, from: backup)
                }
            }

            if let capturedText, !capturedText.isEmpty {
                return .success(text: capturedText, source: .copyFallback)
            }

            if didChange {
                return .empty(.nonTextSelection)
            }

            return .empty(.clipboardUnchanged)
        }

        return .empty(.noSelection)
    }

    private func readPasteboardText(_ pb: NSPasteboard) -> String? {
        if let text = pb.string(forType: .string), !text.isEmpty {
            return text
        }
        if let rtfData = pb.data(forType: .rtf),
           let attr = try? NSAttributedString(data: rtfData, options: [:], documentAttributes: nil) {
            let text = attr.string
            if !text.isEmpty { return text }
        }
        return nil
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Any]] {
        let items = pb.pasteboardItems ?? []
        return items.map { item in
            var payload: [NSPasteboard.PasteboardType: Any] = [:]
            for type in item.types {
                if let plist = item.pasteboardPropertyList(forType: type) {
                    payload[type] = plist
                }
            }
            return payload
        }
    }

    @MainActor
    private func restorePasteboard(
        _ pb: NSPasteboard,
        from snapshot: [[NSPasteboard.PasteboardType: Any]]
    ) {
        pb.clearContents()
        for payload in snapshot {
            let item = NSPasteboardItem()
            for (type, plist) in payload {
                item.setPropertyList(plist, forType: type)
            }
            pb.writeObjects([item])
        }
    }

    private func postCopyEvent() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            print("[selection_capture] event_source_failed")
            return false
        }
        let cmdKey: CGKeyCode = 55 // Left Command
        let cKey: CGKeyCode = 8 // US layout 'c'

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else {
                return false
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            return true
        }

        let cmdDown = post(cmdKey, down: true, flags: [.maskCommand])
        let cDown = post(cKey, down: true, flags: [.maskCommand])
        let cUp = post(cKey, down: false, flags: [.maskCommand])
        let cmdUp = post(cmdKey, down: false, flags: [])
        return cmdDown && cDown && cUp && cmdUp
    }

    private func elapsedMs(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func log(result: SelectionCaptureResult, elapsedMs: Int) {
        switch result {
        case .success(let text, let source):
            print("[selection_capture] ok source=\(source.rawValue) len=\(text.count) ms=\(elapsedMs)")
        case .empty(let reason):
            print("[selection_capture] empty reason=\(reason.rawValue) ms=\(elapsedMs)")
        case .failure(let reason):
            print("[selection_capture] failure reason=\(reason.rawValue) ms=\(elapsedMs)")
        }
    }
}
