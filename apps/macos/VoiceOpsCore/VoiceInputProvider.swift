import Foundation

enum VoiceInputProvider: String, Equatable, Sendable {
    /// The existing path: prefer the ESP32 USB Audio device and fall back to
    /// the current CoreAudio input when that board is not attached.
    case usbAudio
    /// PCM audio and controls supplied by the M5Stack StopWatch over the LAN.
    case wirelessStopWatch

    var requiresMicrophonePermission: Bool {
        self == .usbAudio
    }
}

// MARK: - Shared provider boundary

/// Transport-neutral boundary used by the app today and by a future local
/// inVoice Device Manager.  The legacy USB implementation remains an adapter
/// over the existing CoreAudio/HID services; the wireless implementation owns
/// discovery, authentication and leasing itself.
@MainActor
protocol VoiceProvider: AnyObject {
    var kind: VoiceInputProvider { get }

    func discover() async throws -> [VoiceProviderDevice]
    func connect(deviceID: String?) async throws
    func disconnect() async
    func startAudio() async throws -> VoiceAudioLease?
    func stopAudio() async
    func sendControl(_ control: VoiceProviderControl) async throws
    func getStatus() async throws -> VoiceProviderDeviceStatus
    func updateFirmware(_ image: Data) async throws
}

/// The process boundary intentionally mirrors `VoiceProvider`.  Replacing the
/// in-process wireless provider with a launch agent over a Unix socket will not
/// change callers or the wire protocol used by the StopWatch.
@MainActor
protocol VoiceDeviceManaging: VoiceProvider {}

struct VoiceProviderDevice: Codable, Equatable, Identifiable, Sendable {
    let deviceID: String
    var nickname: String
    let model: String
    var firmwareVersion: String
    let protocolVersion: UInt16
    var bindingEpoch: UInt32
    var isBound: Bool
    var isOnline: Bool

    var id: String { deviceID }
}

enum VoiceProviderRole: String, Codable, CaseIterable, Sendable {
    case owner
    case controller
    case viewer

    func allows(_ permission: VoiceProviderPermission) -> Bool {
        switch (self, permission) {
        case (.owner, _):
            return true
        case (.controller, .audio), (.controller, .control),
             (.controller, .readStatus):
            return true
        case (.viewer, .readStatus):
            return true
        default:
            return false
        }
    }
}

enum VoiceProviderPermission: Sendable {
    case readStatus
    case audio
    case control
    case updateFirmware
    case manageClients
    case factoryReset
}

struct VoiceAudioLease: Codable, Equatable, Sendable {
    let leaseID: UUID
    let deviceID: String
    let clientID: UUID
    let sessionID: UUID
    let acquiredAt: Date
    var expiresAt: Date
}

struct VoiceProviderDeviceStatus: Codable, Equatable, Sendable {
    var device: VoiceProviderDevice
    var batteryPercent: UInt8?
    var role: VoiceProviderRole?
    var activeLease: VoiceAudioLease?
    var activeLeaseAppID: String?
}

enum VoiceProviderControl: Equatable, Sendable {
    case clipboard
    case setNickname(String)
    case revokeClient(UUID)
    case transferOwnership(clientID: UUID, retainPreviousOwner: Bool)
    case forceReleaseAudio
    case forceRebind
    case factoryReset
}

enum VoiceProviderErrorCode: String, Codable, Error, CaseIterable, Sendable {
    case unauthorized = "UNAUTHORIZED"
    case pairingDisabled = "PAIRING_DISABLED"
    case invalidPairCode = "INVALID_PAIR_CODE"
    case pairCodeExpired = "PAIR_CODE_EXPIRED"
    case deviceBusy = "DEVICE_BUSY"
    case leaseExpired = "LEASE_EXPIRED"
    case protocolVersionMismatch = "PROTOCOL_VERSION_MISMATCH"
    case otaNotAllowed = "OTA_NOT_ALLOWED"
    case deviceNotFound = "DEVICE_NOT_FOUND"
    case invalidMessage = "INVALID_MESSAGE"
    case rateLimited = "RATE_LIMITED"
}

// MARK: - Wireless protocol v2

enum WirelessProtocolV2 {
    static let version: UInt16 = 2
    static let serviceType = "_mlxvoice._tcp."
    static let serviceDomain = "local."
    static let pairingWindow: TimeInterval = 120
    static let maximumPairingAttempts = 5
    static let leaseDuration: TimeInterval = 6
    static let heartbeatInterval: TimeInterval = 2
}

enum WirelessMessageType: String, Codable, CaseIterable, Sendable {
    case discover
    case deviceInfo = "device_info"
    case pairStart = "pair_start"
    case pairConfirm = "pair_confirm"
    case pairComplete = "pair_complete"
    case authenticate
    case authenticateChallenge = "authenticate_challenge"
    case authenticated
    case heartbeat
    case acquireAudioLease = "acquire_audio_lease"
    case audioLeaseAcquired = "audio_lease_acquired"
    case releaseAudioLease = "release_audio_lease"
    case pttDown = "ptt_down"
    case pttUp = "ptt_up"
    case audioFrame = "audio_frame"
    case deviceStatus = "device_status"
    case control
    case otaStart = "ota_start"
    case otaProgress = "ota_progress"
    case otaComplete = "ota_complete"
    case revokeClient = "revoke_client"
    case transferOwnership = "transfer_ownership"
    case forceRebind = "force_rebind"
    case factoryReset = "factory_reset"
    case error
}

/// Metadata carried by every v2 JSON message. Binary audio frames are scoped
/// to the mutually-authenticated session and carry the same IDs in their v2
/// binary header.
struct WirelessProtocolHeader: Codable, Equatable, Sendable {
    let protocolVersion: UInt16
    let deviceID: String
    let clientID: String
    let sessionID: String
    let messageID: String
    let timestamp: Int64
    let messageType: WirelessMessageType

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceID = "device_id"
        case clientID = "client_id"
        case sessionID = "session_id"
        case messageID = "message_id"
        case timestamp
        case messageType = "message_type"
    }

    init(
        deviceID: String,
        clientID: String,
        sessionID: String,
        messageID: String = UUID().uuidString.lowercased(),
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        messageType: WirelessMessageType
    ) {
        self.protocolVersion = WirelessProtocolV2.version
        self.deviceID = deviceID
        self.clientID = clientID
        self.sessionID = sessionID
        self.messageID = messageID
        self.timestamp = timestamp
        self.messageType = messageType
    }
}

struct WirelessProtocolMessage: Codable, Equatable, Sendable {
    var header: WirelessProtocolHeader
    var payload: [String: String]
    var signature: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceID = "device_id"
        case clientID = "client_id"
        case sessionID = "session_id"
        case messageID = "message_id"
        case timestamp
        case messageType = "message_type"
        case payload
        case signature
    }

    init(header: WirelessProtocolHeader, payload: [String: String] = [:], signature: String? = nil) {
        self.header = header
        self.payload = payload
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = WirelessProtocolHeader(
            deviceID: try container.decode(String.self, forKey: .deviceID),
            clientID: try container.decode(String.self, forKey: .clientID),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            messageID: try container.decode(String.self, forKey: .messageID),
            timestamp: try container.decode(Int64.self, forKey: .timestamp),
            messageType: try container.decode(WirelessMessageType.self, forKey: .messageType)
        )
        let version = try container.decode(UInt16.self, forKey: .protocolVersion)
        guard version == WirelessProtocolV2.version else {
            throw VoiceProviderErrorCode.protocolVersionMismatch
        }
        payload = try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header.protocolVersion, forKey: .protocolVersion)
        try container.encode(header.deviceID, forKey: .deviceID)
        try container.encode(header.clientID, forKey: .clientID)
        try container.encode(header.sessionID, forKey: .sessionID)
        try container.encode(header.messageID, forKey: .messageID)
        try container.encode(header.timestamp, forKey: .timestamp)
        try container.encode(header.messageType, forKey: .messageType)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(signature, forKey: .signature)
    }

    /// Deterministic bytes signed with P-256/SHA-256. Payload keys are sorted
    /// so Swift, ESP-IDF and a future Device Manager produce identical input.
    func signingBytes() -> Data {
        let fields = payload.keys.sorted().map { "\($0)=\(payload[$0] ?? "")" }
        let canonical = ([
            "MLXVOICE-V2",
            String(header.protocolVersion),
            header.deviceID,
            header.clientID,
            header.sessionID,
            header.messageID,
            String(header.timestamp),
            header.messageType.rawValue,
        ] + fields).joined(separator: "\n")
        return Data(canonical.utf8)
    }
}

// MARK: - Pure state machines (shared by tests and manager implementations)

struct WirelessPairingGate: Equatable, Sendable {
    private(set) var bindingEpoch: UInt32
    private(set) var code: String?
    private(set) var expiresAt: Date?
    private(set) var failedAttempts = 0

    init(bindingEpoch: UInt32 = 1) {
        self.bindingEpoch = max(bindingEpoch, 1)
    }

    mutating func open(code: String, now: Date, forceRebind: Bool = false) {
        precondition(code.count == 6 && code.allSatisfy(\.isNumber))
        if forceRebind { bindingEpoch &+= 1 }
        self.code = code
        expiresAt = now.addingTimeInterval(WirelessProtocolV2.pairingWindow)
        failedAttempts = 0
    }

    mutating func confirm(code candidate: String, now: Date) -> Result<Void, VoiceProviderErrorCode> {
        guard let code, let expiresAt else {
            return .failure(.pairingDisabled)
        }
        guard now < expiresAt else {
            close()
            return .failure(.pairCodeExpired)
        }
        guard failedAttempts < WirelessProtocolV2.maximumPairingAttempts else {
            close()
            return .failure(.pairingDisabled)
        }
        guard candidate == code else {
            failedAttempts += 1
            if failedAttempts >= WirelessProtocolV2.maximumPairingAttempts {
                close()
            }
            return .failure(.invalidPairCode)
        }
        close()
        return .success(())
    }

    mutating func close() {
        code = nil
        expiresAt = nil
    }
}

enum WirelessLeaseDecision: Equatable, Sendable {
    case acquired(VoiceAudioLease)
    case renewed(VoiceAudioLease)
    case busy(VoiceAudioLease)
    case denied(VoiceProviderErrorCode)
}

struct WirelessAudioLeaseCoordinator: Equatable, Sendable {
    private(set) var activeLease: VoiceAudioLease?

    mutating func acquire(
        deviceID: String,
        clientID: UUID,
        sessionID: UUID,
        role: VoiceProviderRole,
        now: Date,
        force: Bool = false
    ) -> WirelessLeaseDecision {
        expire(now: now)
        guard role.allows(.audio) else { return .denied(.unauthorized) }
        if var lease = activeLease {
            if lease.clientID == clientID && lease.sessionID == sessionID {
                lease.expiresAt = now.addingTimeInterval(WirelessProtocolV2.leaseDuration)
                activeLease = lease
                return .renewed(lease)
            }
            guard force, role == .owner else { return .busy(lease) }
        }
        let lease = VoiceAudioLease(
            leaseID: UUID(),
            deviceID: deviceID,
            clientID: clientID,
            sessionID: sessionID,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(WirelessProtocolV2.leaseDuration)
        )
        activeLease = lease
        return .acquired(lease)
    }

    mutating func heartbeat(leaseID: UUID, now: Date) -> Result<VoiceAudioLease, VoiceProviderErrorCode> {
        expire(now: now)
        guard var lease = activeLease, lease.leaseID == leaseID else {
            return .failure(.leaseExpired)
        }
        lease.expiresAt = now.addingTimeInterval(WirelessProtocolV2.leaseDuration)
        activeLease = lease
        return .success(lease)
    }

    mutating func release(leaseID: UUID, clientID: UUID, role: VoiceProviderRole, force: Bool = false) -> Bool {
        guard let lease = activeLease else { return false }
        guard lease.leaseID == leaseID else { return false }
        guard lease.clientID == clientID || (force && role == .owner) else { return false }
        activeLease = nil
        return true
    }

    mutating func expire(now: Date) {
        if let lease = activeLease, now >= lease.expiresAt {
            activeLease = nil
        }
    }
}

struct WirelessDeviceDirectory: Equatable, Sendable {
    private(set) var devicesByID: [String: VoiceProviderDevice] = [:]

    var devices: [VoiceProviderDevice] {
        devicesByID.values.sorted { lhs, rhs in
            if lhs.nickname == rhs.nickname { return lhs.deviceID < rhs.deviceID }
            return lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending
        }
    }

    mutating func upsert(_ device: VoiceProviderDevice) {
        devicesByID[device.deviceID] = device
    }

    mutating func markOffline(deviceID: String) {
        guard var device = devicesByID[deviceID] else { return }
        device.isOnline = false
        devicesByID[deviceID] = device
    }

    func device(id: String) -> VoiceProviderDevice? {
        devicesByID[id]
    }
}

struct WirelessVoiceAudioPacket: Equatable, Sendable {
    static let headerSize = 16
    static let v2HeaderSize = 144
    static let maximumSampleCount = 4_096

    let sequence: UInt32
    let sampleRate: UInt32
    let sampleCount: UInt16
    let level: UInt8
    let flags: UInt8
    let pcm16LE: Data
    let protocolVersion: UInt16
    let timestampMilliseconds: UInt64?
    let deviceID: String?
    let clientID: String?
    let sessionID: String?
    let messageID: Data?

    init(data: Data) throws {
        guard data.count >= Self.headerSize else {
            throw WirelessVoicePacketError.truncatedHeader
        }
        let magic = data.prefix(4)
        guard magic == Data([0x49, 0x56, 0x41, 0x31]) ||
              magic == Data([0x49, 0x56, 0x41, 0x32]) else {
            throw WirelessVoicePacketError.invalidMagic
        }
        let isV2 = magic.last == 0x32
        let headerBytes: Int
        let sequence: UInt32
        let sampleRate: UInt32
        let sampleCount: UInt16
        let level: UInt8
        let flags: UInt8
        let protocolVersion: UInt16
        var timestampMilliseconds: UInt64?
        var deviceID: String?
        var clientID: String?
        var sessionID: String?
        var messageID: Data?
        if isV2 {
            guard data.count >= Self.v2HeaderSize else {
                throw WirelessVoicePacketError.truncatedHeader
            }
            protocolVersion = Self.u16LE(data, offset: 4)
            guard protocolVersion == WirelessProtocolV2.version else {
                throw WirelessVoicePacketError.invalidProtocolVersion(protocolVersion)
            }
            headerBytes = Int(Self.u16LE(data, offset: 6))
            guard headerBytes == Self.v2HeaderSize else {
                throw WirelessVoicePacketError.invalidHeaderSize(headerBytes)
            }
            sequence = Self.u32LE(data, offset: 8)
            sampleRate = Self.u32LE(data, offset: 12)
            sampleCount = Self.u16LE(data, offset: 16)
            level = data[18]
            flags = data[19]
            timestampMilliseconds = Self.u64LE(data, offset: 20)
            deviceID = Self.fixedString(data, offset: 28, count: 20)
            clientID = Self.fixedString(data, offset: 48, count: 40)
            sessionID = Self.fixedString(data, offset: 88, count: 40)
            messageID = Data(data[128..<144])
            guard deviceID?.hasPrefix("MV-") == true,
                  clientID?.isEmpty == false,
                  sessionID?.isEmpty == false else {
                throw WirelessVoicePacketError.invalidIdentity
            }
        } else {
            headerBytes = Self.headerSize
            sequence = Self.u32LE(data, offset: 4)
            sampleRate = Self.u32LE(data, offset: 8)
            sampleCount = Self.u16LE(data, offset: 12)
            level = data[14]
            flags = data[15]
            protocolVersion = 1
        }
        guard sampleRate >= 8_000, sampleRate <= 48_000 else {
            throw WirelessVoicePacketError.invalidSampleRate(sampleRate)
        }
        guard sampleCount > 0, sampleCount <= Self.maximumSampleCount else {
            throw WirelessVoicePacketError.invalidSampleCount(sampleCount)
        }

        let expectedSize = headerBytes + Int(sampleCount) * MemoryLayout<Int16>.size
        guard data.count == expectedSize else {
            throw WirelessVoicePacketError.invalidPayloadSize(
                expected: expectedSize,
                actual: data.count
            )
        }

        self.sequence = sequence
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.level = level
        self.flags = flags
        self.protocolVersion = protocolVersion
        self.timestampMilliseconds = timestampMilliseconds
        self.deviceID = deviceID
        self.clientID = clientID
        self.sessionID = sessionID
        self.messageID = messageID
        self.pcm16LE = Data(data[headerBytes...])
    }

    private static func u16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func u64LE(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func fixedString(_ data: Data, offset: Int, count: Int) -> String? {
        let bytes = data[offset..<(offset + count)]
        let content = bytes.prefix { $0 != 0 }
        return String(data: Data(content), encoding: .utf8)
    }
}

enum WirelessVoicePacketError: Error, Equatable {
    case truncatedHeader
    case invalidMagic
    case invalidProtocolVersion(UInt16)
    case invalidHeaderSize(Int)
    case invalidIdentity
    case invalidSampleRate(UInt32)
    case invalidSampleCount(UInt16)
    case invalidPayloadSize(expected: Int, actual: Int)
}
