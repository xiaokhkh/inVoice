import AppKit
import ApplicationServices
import Carbon
import IOKit.hid

final class FnKeyMonitor {
    private struct BoardControlState {
        var triggerDown = false
        var clipboardDown = false
    }

    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onFnSpace: (() -> Void)?
    var onClipboardToggle: (() -> Void)?
    var onTranslateSelection: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isActivationDown = false
    private var isBoardTriggerDown = false
    private var isBoardClipboardDown = false
    private var isClipboardDown = false
    private var isTranslateDown = false
    private var boardHIDManager: IOHIDManager?
    private var boardDeviceStates: [UInt64: BoardControlState] = [:]
    private var usesLegacyBoardEventFallback = false
    private let fnKeyCode: CGKeyCode = CGKeyCode(kVK_Function)
    // The ESP32 composite USB device emits F13 as its private PTT signal.
    private let boardTriggerKeyCode: CGKeyCode = CGKeyCode(kVK_F13)
    // BOOT emits F14 as a dedicated clipboard-panel control.
    private let boardClipboardKeyCode: CGKeyCode = CGKeyCode(kVK_F14)
    private let boardVendorID = 0x303A
    private let boardProductID = 0x4002
    private let boardTriggerUsage: UInt32 = 0x68
    private let boardClipboardUsage: UInt32 = 0x69
    private var activationKeyCode: CGKeyCode = CGKeyCode(kVK_Function)
    private var activationModifiers: UInt32 = 0
    private var clipboardKeyCode: CGKeyCode = CGKeyCode(kVK_Function)
    private var clipboardModifiers: UInt32 = UInt32(cmdKey)
    private var translateKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_T)
    private var translateModifiers: UInt32 = UInt32(cmdKey | optionKey)

    private var activationUsesFn: Bool {
        activationKeyCode == fnKeyCode && activationModifiers == 0
    }

    private var clipboardUsesFn: Bool {
        clipboardKeyCode == fnKeyCode
    }

    private var translateUsesFn: Bool {
        translateKeyCode == fnKeyCode
    }

    private func dispatchAction(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    func start() {
        ensureEventTap()
        if eventTap == nil {
            startFallbackMonitors()
        }
    }

    func stop() {
        stopBoardHIDMonitor()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        runLoopSource = nil
        eventTap = nil
        globalMonitor = nil
        localMonitor = nil
        isActivationDown = false
        isBoardTriggerDown = false
        isBoardClipboardDown = false
        isClipboardDown = false
        isTranslateDown = false
        usesLegacyBoardEventFallback = false
    }

    func updateActivationKey(keyCode: UInt32, modifiers: UInt32) {
        activationKeyCode = CGKeyCode(keyCode)
        activationModifiers = modifiers
        isActivationDown = false
    }

    func updateClipboardShortcut(keyCode: UInt32, modifiers: UInt32) {
        clipboardKeyCode = CGKeyCode(keyCode)
        clipboardModifiers = modifiers
        isClipboardDown = false
    }

    func updateTranslateShortcut(keyCode: UInt32, modifiers: UInt32) {
        translateKeyCode = CGKeyCode(keyCode)
        translateModifiers = modifiers
        isTranslateDown = false
    }

    func ensureEventTap() {
        if boardHIDManager == nil {
            usesLegacyBoardEventFallback = !startBoardHIDMonitor()
        }
        guard eventTap == nil else { return }
        if !startEventTap() {
            startFallbackMonitors()
        }
    }

    private func startBoardHIDMonitor() -> Bool {
        guard boardHIDManager == nil else { return true }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: boardVendorID,
            kIOHIDProductIDKey: boardProductID,
            kIOHIDPrimaryUsagePageKey: Int(kHIDPage_GenericDesktop),
            kIOHIDPrimaryUsageKey: Int(kHIDUsage_GD_Keyboard),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let deviceMatched: IOHIDDeviceCallback = { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            let identifier = monitor.boardIdentifier(for: device)
            monitor.dispatchAction { [weak monitor] in
                monitor?.boardDeviceMatched(identifier: identifier)
            }
        }
        let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            let identifier = monitor.boardIdentifier(for: device)
            monitor.dispatchAction { [weak monitor] in
                monitor?.boardDeviceRemoved(identifier: identifier)
            }
        }
        let inputValue: IOHIDValueCallback = { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else {
                return
            }
            let usage = IOHIDElementGetUsage(element)
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            guard usage == monitor.boardTriggerUsage
                    || usage == monitor.boardClipboardUsage else {
                return
            }
            let identifier = monitor.boardIdentifier(for: IOHIDElementGetDevice(element))
            let isDown = IOHIDValueGetIntegerValue(value) != 0
            monitor.dispatchAction { [weak monitor] in
                monitor?.handleBoardValue(identifier: identifier, usage: usage, isDown: isDown)
            }
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, inputValue, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            trace("[trigger] board_hid_open_failed result=\(result)")
            return false
        }

        boardHIDManager = manager
        trace("[trigger] board_hid_monitor=started")
        return true
    }

    private func stopBoardHIDMonitor() {
        boardDeviceStates.removeAll()
        handleBoardTriggerState(isDown: false)
        handleBoardClipboardState(isDown: false)
        guard let manager = boardHIDManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                          CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        boardHIDManager = nil
    }

    private func boardIdentifier(for device: IOHIDDevice) -> UInt64 {
        var identifier: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0,
           IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS
        {
            return identifier
        }
        return UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private func boardDeviceMatched(identifier: UInt64) {
        if boardDeviceStates[identifier] == nil {
            boardDeviceStates[identifier] = BoardControlState()
            trace("[trigger] board_hid_device=matched id=\(identifier)")
        }
    }

    private func boardDeviceRemoved(identifier: UInt64) {
        guard boardDeviceStates.removeValue(forKey: identifier) != nil else { return }
        trace("[trigger] board_hid_device=removed id=\(identifier)")
        publishAggregatedBoardState()
    }

    private func handleBoardValue(identifier: UInt64, usage: UInt32, isDown: Bool) {
        var state = boardDeviceStates[identifier] ?? BoardControlState()
        if usage == boardTriggerUsage {
            guard state.triggerDown != isDown else { return }
            state.triggerDown = isDown
        } else if usage == boardClipboardUsage {
            guard state.clipboardDown != isDown else { return }
            state.clipboardDown = isDown
        } else {
            return
        }
        boardDeviceStates[identifier] = state
        publishAggregatedBoardState()
    }

    private func publishAggregatedBoardState() {
        let triggerDown = boardDeviceStates.values.contains { $0.triggerDown }
        let clipboardDown = boardDeviceStates.values.contains { $0.clipboardDown }
        handleBoardTriggerState(isDown: triggerDown)
        handleBoardClipboardState(isDown: clipboardDown)
    }

    private func startEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEventTap(proxy: proxy, type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        stopFallbackMonitors()
        return true
    }

    private func stopFallbackMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func startFallbackMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                self?.handleFallbackEvent(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                let shouldSwallow = self.handleFallbackEvent(event)
                return shouldSwallow ? nil : event
            }
        }
    }

    private func handleEventTap(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let fnNow = event.flags.contains(.maskSecondaryFn)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            if clipboardUsesFn {
                handleClipboardFnCombo(fnNow: fnNow, flags: event.flags)
            }
            if translateUsesFn {
                handleTranslateFnCombo(fnNow: fnNow, flags: event.flags)
            }
            if keyCode == Int64(fnKeyCode) {
                if activationUsesFn {
                    handleFnActivationState(fnNow: fnNow)
                }
            }
        } else if type == .keyDown {
            if keyCode == Int64(boardTriggerKeyCode) {
                if usesLegacyBoardEventFallback,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    handleBoardTriggerState(isDown: true)
                }
                return nil
            }
            if keyCode == Int64(boardClipboardKeyCode) {
                if usesLegacyBoardEventFallback,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    handleBoardClipboardState(isDown: true)
                }
                return nil
            }
            if onClipboardToggle != nil, !clipboardUsesFn {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat, matchesClipboardShortcut(keyCode: keyCode, flags: event.flags) {
                    isClipboardDown = true
                    dispatchAction { [weak self] in
                        self?.onClipboardToggle?()
                    }
                    return nil
                }
            }
            if onTranslateSelection != nil, !translateUsesFn {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat, matchesTranslateShortcut(keyCode: keyCode, flags: event.flags) {
                    isTranslateDown = true
                    dispatchAction { [weak self] in
                        self?.onTranslateSelection?()
                    }
                    return nil
                }
            }
            if !activationUsesFn {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat, keyCode == Int64(activationKeyCode), matchesActivationModifiers(flags: event.flags) {
                    if !isActivationDown {
                        isActivationDown = true
                        if !isBoardTriggerDown {
                            dispatchAction { [weak self] in
                                self?.onFnDown?()
                            }
                        }
                    }
                    return nil
                }
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if keyCode == 49, !isRepeat, onFnSpace != nil {
                dispatchAction { [weak self] in
                    self?.onFnSpace?()
                }
                return nil
            }
        } else if type == .keyUp {
            if keyCode == Int64(boardTriggerKeyCode) {
                if usesLegacyBoardEventFallback {
                    handleBoardTriggerState(isDown: false)
                }
                return nil
            }
            if keyCode == Int64(boardClipboardKeyCode) {
                if usesLegacyBoardEventFallback {
                    handleBoardClipboardState(isDown: false)
                }
                return nil
            }
            if !clipboardUsesFn, isClipboardDown, keyCode == Int64(clipboardKeyCode) {
                isClipboardDown = false
                return nil
            }
            if !translateUsesFn, isTranslateDown, keyCode == Int64(translateKeyCode) {
                isTranslateDown = false
                return nil
            }
            if !activationUsesFn, keyCode == Int64(activationKeyCode) {
                if isActivationDown {
                    isActivationDown = false
                    if !isBoardTriggerDown {
                        dispatchAction { [weak self] in
                            self?.onFnUp?()
                        }
                    }
                }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func handleFallbackEvent(_ event: NSEvent) -> Bool {
        let fnNow = event.modifierFlags.contains(.function)
        switch event.type {
        case .flagsChanged:
            if clipboardUsesFn {
                handleClipboardFnCombo(fnNow: fnNow, flags: event.modifierFlags)
            }
            if translateUsesFn {
                handleTranslateFnCombo(fnNow: fnNow, flags: event.modifierFlags)
            }
            if event.keyCode == fnKeyCode {
                if activationUsesFn {
                    handleFnActivationState(fnNow: fnNow)
                }
            }
        case .keyDown:
            if event.keyCode == boardTriggerKeyCode {
                if usesLegacyBoardEventFallback, !event.isARepeat {
                    handleBoardTriggerState(isDown: true)
                }
                return true
            }
            if event.keyCode == boardClipboardKeyCode {
                if usesLegacyBoardEventFallback, !event.isARepeat {
                    handleBoardClipboardState(isDown: true)
                }
                return true
            }
            if onClipboardToggle != nil, !clipboardUsesFn, !event.isARepeat,
               matchesClipboardShortcut(keyCode: event.keyCode, flags: event.modifierFlags)
            {
                isClipboardDown = true
                dispatchAction { [weak self] in
                    self?.onClipboardToggle?()
                }
                return true
            }
            if onTranslateSelection != nil, !translateUsesFn, !event.isARepeat,
               matchesTranslateShortcut(keyCode: event.keyCode, flags: event.modifierFlags)
            {
                isTranslateDown = true
                dispatchAction { [weak self] in
                    self?.onTranslateSelection?()
                }
                return true
            }
            if !activationUsesFn,
               !event.isARepeat,
               event.keyCode == activationKeyCode,
               matchesActivationModifiers(flags: event.modifierFlags)
            {
                if !isActivationDown {
                    isActivationDown = true
                    if !isBoardTriggerDown {
                        dispatchAction { [weak self] in
                            self?.onFnDown?()
                        }
                    }
                }
                return true
            }
            guard fnNow, event.keyCode == 49, !event.isARepeat else { return false }
            guard onFnSpace != nil else { return false }
            dispatchAction { [weak self] in
                self?.onFnSpace?()
            }
            return true
        case .keyUp:
            if event.keyCode == boardTriggerKeyCode {
                if usesLegacyBoardEventFallback {
                    handleBoardTriggerState(isDown: false)
                }
                return true
            }
            if event.keyCode == boardClipboardKeyCode {
                if usesLegacyBoardEventFallback {
                    handleBoardClipboardState(isDown: false)
                }
                return true
            }
            if !clipboardUsesFn, isClipboardDown, event.keyCode == clipboardKeyCode {
                isClipboardDown = false
                return true
            }
            if !translateUsesFn, isTranslateDown, event.keyCode == translateKeyCode {
                isTranslateDown = false
                return true
            }
            if !activationUsesFn, event.keyCode == activationKeyCode {
                if isActivationDown {
                    isActivationDown = false
                    if !isBoardTriggerDown {
                        dispatchAction { [weak self] in
                            self?.onFnUp?()
                        }
                    }
                }
                return true
            }
            return true
        default:
            break
        }
        return false
    }

    private func handleClipboardFnCombo(fnNow: Bool, flags: CGEventFlags) {
        guard clipboardUsesFn, onClipboardToggle != nil else { return }
        let comboActive = fnNow && effectiveModifiers(from: flags) == clipboardModifiers
        if comboActive && !isClipboardDown {
            isClipboardDown = true
            dispatchAction { [weak self] in
                self?.onClipboardToggle?()
            }
            return
        }
        if !comboActive && isClipboardDown {
            isClipboardDown = false
        }
    }

    private func handleTranslateFnCombo(fnNow: Bool, flags: CGEventFlags) {
        guard translateUsesFn, onTranslateSelection != nil else { return }
        let comboActive = fnNow && effectiveModifiers(from: flags) == translateModifiers
        if comboActive && !isTranslateDown {
            isTranslateDown = true
            dispatchAction { [weak self] in
                self?.onTranslateSelection?()
            }
            return
        }
        if !comboActive && isTranslateDown {
            isTranslateDown = false
        }
    }

    private func handleClipboardFnCombo(fnNow: Bool, flags: NSEvent.ModifierFlags) {
        guard clipboardUsesFn, onClipboardToggle != nil else { return }
        let comboActive = fnNow && effectiveModifiers(from: flags) == clipboardModifiers
        if comboActive && !isClipboardDown {
            isClipboardDown = true
            dispatchAction { [weak self] in
                self?.onClipboardToggle?()
            }
            return
        }
        if !comboActive && isClipboardDown {
            isClipboardDown = false
        }
    }

    private func handleTranslateFnCombo(fnNow: Bool, flags: NSEvent.ModifierFlags) {
        guard translateUsesFn, onTranslateSelection != nil else { return }
        let comboActive = fnNow && effectiveModifiers(from: flags) == translateModifiers
        if comboActive && !isTranslateDown {
            isTranslateDown = true
            dispatchAction { [weak self] in
                self?.onTranslateSelection?()
            }
            return
        }
        if !comboActive && isTranslateDown {
            isTranslateDown = false
        }
    }

    private func handleFnActivationState(fnNow: Bool) {
        if fnNow && !isActivationDown {
            isActivationDown = true
            if !isBoardTriggerDown {
                dispatchAction { [weak self] in
                    self?.onFnDown?()
                }
            }
        } else if !fnNow && isActivationDown {
            isActivationDown = false
            if !isBoardTriggerDown {
                dispatchAction { [weak self] in
                    self?.onFnUp?()
                }
            }
        }
    }

    private func handleBoardTriggerState(isDown: Bool) {
        if isDown && !isBoardTriggerDown {
            isBoardTriggerDown = true
            trace("[trigger] source=board state=down activation_down=\(isActivationDown)")
            if !isActivationDown {
                dispatchAction { [weak self] in
                    self?.onFnDown?()
                }
            }
        } else if !isDown && isBoardTriggerDown {
            isBoardTriggerDown = false
            trace("[trigger] source=board state=up activation_down=\(isActivationDown)")
            if !isActivationDown {
                dispatchAction { [weak self] in
                    self?.onFnUp?()
                }
            }
        }
    }

    private func handleBoardClipboardState(isDown: Bool) {
        if isDown && !isBoardClipboardDown {
            isBoardClipboardDown = true
            trace("[trigger] source=board_clipboard state=down")
            dispatchAction { [weak self] in
                self?.onClipboardToggle?()
            }
        } else if !isDown && isBoardClipboardDown {
            isBoardClipboardDown = false
            trace("[trigger] source=board_clipboard state=up")
        }
    }

    private func matchesActivationModifiers(flags: CGEventFlags) -> Bool {
        effectiveModifiers(from: flags) == activationModifiers
    }

    private func matchesActivationModifiers(flags: NSEvent.ModifierFlags) -> Bool {
        effectiveModifiers(from: flags) == activationModifiers
    }

    private func matchesClipboardShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(clipboardKeyCode) && effectiveModifiers(from: flags) == clipboardModifiers
    }

    private func matchesClipboardShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == clipboardKeyCode && effectiveModifiers(from: flags) == clipboardModifiers
    }

    private func matchesTranslateShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(translateKeyCode) && effectiveModifiers(from: flags) == translateModifiers
    }

    private func matchesTranslateShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == translateKeyCode && effectiveModifiers(from: flags) == translateModifiers
    }

    private func effectiveModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.maskAlternate) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.maskControl) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.maskShift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    private func effectiveModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    private func trace(_ message: String) {
        NSLog("%@", message)
    }
}
