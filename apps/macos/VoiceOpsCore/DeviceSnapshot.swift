import Foundation

enum DeviceBindingState: Equatable, Sendable {
    case unbound
    case bound(VoiceProviderRole)
    case credentialInvalid

    var role: VoiceProviderRole? {
        guard case .bound(let role) = self else { return nil }
        return role
    }

    var isBound: Bool {
        role != nil
    }
}

enum DeviceReachabilityState: String, Equatable, Sendable {
    case offline
    case ble
    case bonjour
    case bleAndBonjour

    var isReachable: Bool { self != .offline }
    var isBonjourVisible: Bool { self == .bonjour || self == .bleAndBonjour }
    var isBLEVisible: Bool { self == .ble || self == .bleAndBonjour }
}

enum DeviceSessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case authenticated
    case reconnecting
}

enum DeviceAudioState: Equatable, Sendable {
    case idle
    case leased
    case busy(appID: String?, clientID: String?)
    case expired
}

enum DeviceJourneyStage: String, Equatable, Sendable {
    case unknown
    case discovered
    case awaitingPhysicalConfirmation
    case securePairing
    case provisioningWiFi
    case awaitingBonjour
    case authenticating
    case ready
    case audioLeased
    case busy
    case reconnecting
    case offline
}

enum DeviceRecoveryAction: String, Equatable, Sendable {
    case retry
    case rescan
    case checkPhysicalDevice
    case enterPairingMode
    case reenterPairingCode
    case checkWiFi
    case rebind
    case releaseAudioLease
    case updateFirmware
}

struct DeviceActionError: Error, Equatable, Sendable {
    let stage: DeviceJourneyStage
    let code: VoiceProviderErrorCode
    let message: String
    let recovery: DeviceRecoveryAction
}

struct DeviceSnapshot: Equatable, Identifiable, Sendable {
    let deviceID: String
    var nickname: String
    var model: String
    var firmwareVersion: String
    var protocolVersion: UInt16
    var bindingEpoch: UInt32
    var binding: DeviceBindingState
    var reachability: DeviceReachabilityState
    var session: DeviceSessionState
    var audio: DeviceAudioState
    var batteryPercent: UInt8?
    var lastSeenAt: Date?
    var lastError: DeviceActionError?

    var id: String { deviceID }

    var shortID: String {
        String(deviceID.split(separator: "-").last ?? Substring(deviceID))
    }

    var stage: DeviceJourneyStage {
        switch session {
        case .authenticated:
            if case .busy = audio { return .busy }
            if audio == .leased { return .audioLeased }
            return .ready
        case .authenticating: return .authenticating
        case .reconnecting: return .reconnecting
        case .connecting: return .authenticating
        case .disconnected:
            return reachability == .offline ? .offline : .discovered
        }
    }
}

enum DeviceStateEvent: Equatable, Sendable {
    case bleVisibility(Bool, at: Date)
    case bonjourDevice(VoiceProviderDevice, at: Date)
    case bonjourLost(at: Date)
    case binding(WirelessBindingSummary?)
    case session(DeviceSessionState)
    case status(VoiceProviderDeviceStatus)
    case audio(DeviceAudioState)
    case failed(DeviceActionError)
}

/// Secret-free binding material used by the state reducer. The actual key and
/// credentials remain inside the macOS Keychain-backed credential store.
struct WirelessBindingSummary: Equatable, Sendable {
    let deviceID: String
    let nickname: String
    let model: String
    let role: VoiceProviderRole
    let bindingEpoch: UInt32
}

enum DeviceStateReducer {
    static func placeholder(
        deviceID: String,
        nickname: String = "inVoice StopWatch",
        model: String = "M5Stack StopWatch"
    ) -> DeviceSnapshot {
        DeviceSnapshot(
            deviceID: deviceID,
            nickname: nickname,
            model: model,
            firmwareVersion: "unknown",
            protocolVersion: WirelessProtocolV2.version,
            bindingEpoch: 0,
            binding: .unbound,
            reachability: .offline,
            session: .disconnected,
            audio: .idle,
            batteryPercent: nil,
            lastSeenAt: nil,
            lastError: nil
        )
    }

    static func reduce(_ current: DeviceSnapshot, event: DeviceStateEvent) -> DeviceSnapshot {
        var next = current
        switch event {
        case .bleVisibility(let visible, let date):
            next.reachability = reachability(
                ble: visible,
                bonjour: current.reachability.isBonjourVisible
            )
            if visible { next.lastSeenAt = date }
        case .bonjourDevice(let device, let date):
            guard device.deviceID == current.deviceID else { return current }
            next.nickname = device.nickname
            next.model = device.model
            next.firmwareVersion = device.firmwareVersion
            next.protocolVersion = device.protocolVersion
            next.bindingEpoch = device.bindingEpoch
            next.reachability = reachability(
                ble: current.reachability.isBLEVisible,
                bonjour: true
            )
            next.lastSeenAt = date
            if current.binding.isBound,
               let error = bindingEpochError(
                    storedEpoch: current.bindingEpoch,
                    advertisedEpoch: device.bindingEpoch
               ) {
                next.binding = .credentialInvalid
                next.lastError = error
            }
        case .bonjourLost:
            next.reachability = reachability(
                ble: current.reachability.isBLEVisible,
                bonjour: false
            )
            if next.session != .disconnected { next.session = .reconnecting }
            if next.audio == .leased { next.audio = .expired }
            if case .busy = next.audio { next.audio = .idle }
        case .binding(let binding):
            guard let binding else {
                next.binding = .unbound
                if next.lastError?.recovery == .rebind { next.lastError = nil }
                break
            }
            guard binding.deviceID == current.deviceID else { return current }
            next.nickname = binding.nickname
            next.model = binding.model
            if current.bindingEpoch > 0, binding.bindingEpoch != current.bindingEpoch {
                next.binding = .credentialInvalid
                next.lastError = bindingEpochError(
                    storedEpoch: binding.bindingEpoch,
                    advertisedEpoch: current.bindingEpoch
                )
            } else {
                next.binding = .bound(binding.role)
                if next.lastError?.recovery == .rebind { next.lastError = nil }
            }
        case .session(let session):
            next.session = session
            if session == .authenticated { next.lastError = nil }
        case .status(let status):
            guard status.device.deviceID == current.deviceID else { return current }
            next.batteryPercent = status.batteryPercent
            if next.binding != .credentialInvalid, let role = status.role {
                next.binding = .bound(role)
            }
            if let lease = status.activeLease {
                next.audio = .busy(
                    appID: status.activeLeaseAppID,
                    clientID: lease.clientID.uuidString.lowercased()
                )
            } else if let appID = status.activeLeaseAppID, !appID.isEmpty {
                next.audio = .busy(appID: appID, clientID: nil)
            } else if case .busy = next.audio {
                next.audio = .idle
            }
        case .audio(let audio):
            next.audio = audio
        case .failed(let error):
            next.lastError = error
        }
        return next
    }

    private static func reachability(ble: Bool, bonjour: Bool) -> DeviceReachabilityState {
        switch (ble, bonjour) {
        case (true, true): return .bleAndBonjour
        case (true, false): return .ble
        case (false, true): return .bonjour
        case (false, false): return .offline
        }
    }

    private static func bindingEpochError(
        storedEpoch: UInt32,
        advertisedEpoch: UInt32
    ) -> DeviceActionError? {
        guard storedEpoch > 0, storedEpoch != advertisedEpoch else { return nil }
        return DeviceActionError(
            stage: .authenticating,
            code: .unauthorized,
            message: "The device binding changed and this Mac must pair again.",
            recovery: .rebind
        )
    }
}
