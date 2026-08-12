import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid

enum Permissions {
    private static var didPromptAccessibility = false
    private static var didPromptInputMonitoring = false
    private static var didPromptMicrophone = false

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    static func accessibilityStatusInfo() -> (trusted: Bool, bundleID: String, path: String) {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let path = Bundle.main.bundlePath
        return (AXIsProcessTrusted(), bundleID, path)
    }

    static func accessibilityStatus() -> String {
        let info = accessibilityStatusInfo()
        let pid = ProcessInfo.processInfo.processIdentifier
        return "trusted=\(info.trusted) bundle_id=\(info.bundleID) pid=\(pid) path=\(info.path)"
    }

    static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        guard !didPromptAccessibility else { return }
        didPromptAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString
        let options: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func hasInputMonitoring() -> Bool {
        guard #available(macOS 10.15, *) else { return true }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoringIfNeeded() {
        guard #available(macOS 10.15, *) else { return }
        guard !didPromptInputMonitoring else { return }
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard status != kIOHIDAccessTypeGranted else { return }
        didPromptInputMonitoring = true
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard !didPromptMicrophone else { return false }
            didPromptMicrophone = true
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    static func microphoneStatusLabel() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    static func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func microphoneNeedsRequest() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined && !didPromptMicrophone
    }
}
