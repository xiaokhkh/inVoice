import Combine
import CoreBluetooth
import CryptoKit
import Foundation
import os
import Security

struct WirelessClientIdentity: Codable, Equatable {
    let clientID: UUID
    let appID: String
    let privateKeyRaw: Data

    var signingKey: P256.Signing.PrivateKey? {
        try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    var publicKeyBase64: String? {
        signingKey?.publicKey.x963Representation.base64EncodedString()
    }
}

struct WirelessDeviceBinding: Codable, Equatable, Identifiable {
    let deviceID: String
    var nickname: String
    let model: String
    let devicePublicKey: Data
    var role: VoiceProviderRole
    var bindingEpoch: UInt32

    var id: String { deviceID }
}

enum WirelessCredentialStoreError: Error {
    case keychain(OSStatus)
    case invalidIdentity
    case invalidDeviceKey
}

/// The only persistence point for client private keys and device credentials.
/// UserDefaults contains only the non-secret default device ID.
final class WirelessCredentialStore {
    static let shared = WirelessCredentialStore()

    private let service = "com.voiceops.invoice.wireless.v2"
    private let identityAccount = "client-identity"
    private let bindingIndexAccount = "binding-index"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var cachedIdentity: WirelessClientIdentity?
    private var cachedBindings: [String: WirelessDeviceBinding]?

    func clientIdentity() throws -> WirelessClientIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        if let data = try read(account: identityAccount) {
            let identity = try decoder.decode(WirelessClientIdentity.self, from: data)
            guard identity.signingKey != nil else {
                throw WirelessCredentialStoreError.invalidIdentity
            }
            cachedIdentity = identity
            return identity
        }
        let key = P256.Signing.PrivateKey()
        let identity = WirelessClientIdentity(
            clientID: UUID(),
            appID: "invoice",
            privateKeyRaw: key.rawRepresentation
        )
        try write(encoder.encode(identity), account: identityAccount)
        cachedIdentity = identity
        return identity
    }

    func save(binding: WirelessDeviceBinding) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(encoder.encode(binding), account: bindingAccount(binding.deviceID))
        var ids = try bindingIDsUnlocked()
        if !ids.contains(binding.deviceID) {
            ids.append(binding.deviceID)
            ids.sort()
            try write(encoder.encode(ids), account: bindingIndexAccount)
        }
        if cachedBindings == nil {
            let bindings: [WirelessDeviceBinding] = try ids.compactMap { id in
                guard let data = try read(account: bindingAccount(id)) else { return nil }
                return try decoder.decode(WirelessDeviceBinding.self, from: data)
            }
            cachedBindings = Dictionary(
                uniqueKeysWithValues: bindings.map { ($0.deviceID, $0) }
            )
        }
        cachedBindings?[binding.deviceID] = binding
    }

    func binding(deviceID: String) throws -> WirelessDeviceBinding? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedBindings { return cachedBindings[deviceID] }
        guard let data = try read(account: bindingAccount(deviceID)) else { return nil }
        return try decoder.decode(WirelessDeviceBinding.self, from: data)
    }

    func allBindings() throws -> [WirelessDeviceBinding] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedBindings {
            return cachedBindings.values.sorted { $0.deviceID < $1.deviceID }
        }
        let bindings: [WirelessDeviceBinding] = try bindingIDsUnlocked().compactMap { id in
            guard let data = try read(account: bindingAccount(id)) else { return nil }
            return try decoder.decode(WirelessDeviceBinding.self, from: data)
        }
        cachedBindings = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.deviceID, $0) }
        )
        return bindings
    }

    func removeBinding(deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try delete(account: bindingAccount(deviceID))
        let ids = try bindingIDsUnlocked().filter { $0 != deviceID }
        try write(encoder.encode(ids), account: bindingIndexAccount)
        cachedBindings?.removeValue(forKey: deviceID)
    }

    func sign(_ data: Data) throws -> Data {
        let identity = try clientIdentity()
        guard let key = identity.signingKey else {
            throw WirelessCredentialStoreError.invalidIdentity
        }
        return try key.signature(for: data).derRepresentation
    }

    func verifyDeviceSignature(_ signature: Data, data: Data, deviceID: String) throws -> Bool {
        guard let binding = try binding(deviceID: deviceID) else { return false }
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: binding.devicePublicKey)
        } catch {
            throw WirelessCredentialStoreError.invalidDeviceKey
        }
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        return publicKey.isValidSignature(parsed, for: data)
    }

    private func bindingIDsUnlocked() throws -> [String] {
        guard let data = try read(account: bindingIndexAccount) else { return [] }
        return try decoder.decode([String].self, from: data)
    }

    private func bindingAccount(_ deviceID: String) -> String {
        "device:\(deviceID)"
    }

    private func read(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WirelessCredentialStoreError.keychain(status)
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WirelessCredentialStoreError.keychain(updateStatus)
        }
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw WirelessCredentialStoreError.keychain(insertStatus)
        }
    }

    private func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WirelessCredentialStoreError.keychain(status)
        }
    }
}

@MainActor
final class WirelessDeviceCatalog: ObservableObject {
    static let shared = WirelessDeviceCatalog()
    private static let logger = Logger(
        subsystem: "com.voiceops.VoiceOps",
        category: "WirelessCatalog"
    )

    @Published private(set) var devices: [VoiceProviderDevice] = []
    @Published private(set) var statuses: [String: VoiceProviderDeviceStatus] = [:]
    @Published private(set) var bindings: [String: WirelessDeviceBinding] = [:]
    @Published private(set) var clientID: UUID?
    @Published var defaultDeviceID: String? {
        didSet {
            if let defaultDeviceID {
                UserDefaults.standard.set(defaultDeviceID, forKey: "wireless.defaultDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "wireless.defaultDeviceID")
            }
        }
    }

    private var discovered: [String: VoiceProviderDevice] = [:]
    private var refreshGeneration: UInt64 = 0

    private init() {
        defaultDeviceID = UserDefaults.standard.string(forKey: "wireless.defaultDeviceID")
        refresh()
    }

    func update(discovered devices: [VoiceProviderDevice]) {
        discovered = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceID, $0) })
        apply(
            storedBindings: Array(bindings.values),
            clientID: clientID
        )
    }

    func update(status: VoiceProviderDeviceStatus) {
        statuses[status.device.deviceID] = status
        discovered[status.device.deviceID] = status.device
        apply(
            storedBindings: Array(bindings.values),
            clientID: clientID
        )
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let storedBindings: [WirelessDeviceBinding]
            do {
                storedBindings = try WirelessCredentialStore.shared.allBindings()
            } catch {
                storedBindings = []
                Self.logger.error(
                    "Binding load failed: \(String(describing: error), privacy: .public)"
                )
            }
            let storedClientID: UUID?
            do {
                storedClientID = try WirelessCredentialStore.shared.clientIdentity().clientID
            } catch {
                storedClientID = nil
                Self.logger.error(
                    "Client identity load failed: \(String(describing: error), privacy: .public)"
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                Self.logger.info("Loaded \(storedBindings.count, privacy: .public) wireless bindings")
                self.apply(storedBindings: storedBindings, clientID: storedClientID)
            }
        }
    }

    func binding(deviceID: String) -> WirelessDeviceBinding? {
        bindings[deviceID]
    }

    /// Publishes a binding that was just committed to Keychain immediately.
    /// This closes the BLE-to-Wi-Fi handoff race without making the main actor
    /// wait for a second Keychain read.
    func record(binding: WirelessDeviceBinding, clientID: UUID) {
        refreshGeneration &+= 1
        var updatedBindings = bindings
        updatedBindings[binding.deviceID] = binding
        apply(
            storedBindings: Array(updatedBindings.values),
            clientID: clientID
        )
    }

    private func apply(
        storedBindings: [WirelessDeviceBinding],
        clientID: UUID?
    ) {
        let bindingsByID = Dictionary(
            uniqueKeysWithValues: storedBindings.map { ($0.deviceID, $0) }
        )
        bindings = bindingsByID
        self.clientID = clientID
        var merged = discovered
        for (deviceID, binding) in bindingsByID {
            if var device = merged[deviceID] {
                device.isBound = device.bindingEpoch == binding.bindingEpoch
                merged[deviceID] = device
            }
        }
        for binding in storedBindings where merged[binding.deviceID] == nil {
            merged[binding.deviceID] = VoiceProviderDevice(
                deviceID: binding.deviceID,
                nickname: binding.nickname,
                model: binding.model,
                firmwareVersion: "unknown",
                protocolVersion: WirelessProtocolV2.version,
                bindingEpoch: binding.bindingEpoch,
                isBound: true,
                isOnline: false
            )
        }
        devices = merged.values.sorted {
            if $0.nickname == $1.nickname { return $0.deviceID < $1.deviceID }
            return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
        }
        if defaultDeviceID == nil, storedBindings.count == 1 {
            defaultDeviceID = storedBindings[0].deviceID
        }
    }
}

struct NearbyWirelessDevice: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var rssi: Int
    var deviceID: String?
    var nickname: String?
    var model: String?

    var identityLabel: String {
        if let deviceID { return deviceID }
        return "Nearby BLE device · \(id.uuidString.prefix(8))"
    }
}

struct WirelessProvisioningIdentity: Equatable {
    let deviceID: String
    let nickname: String
    let model: String
    let bindingEpoch: UInt32
}

enum WirelessProvisioningPhase: Equatable {
    case idle
    case scanning
    case connecting(UUID)
    case confirmingIdentity(String)
    case awaitingPhysicalConfirmation(String)
    case securePairing(String)
    case provisioningWiFi(String)
    case awaitingBonjour(String)
    case authenticating(String)
    case complete(String)
    case failed(DeviceActionError)
}

enum WirelessBLELinkState: Equatable {
    case unavailable
    case scanning
    case connecting
    case connected
    case identityVerified
    case bindingSecured
    case wifiHandoff
    case failed
}

/// Secure, one-time Wi-Fi provisioning for the wireless StopWatch provider.
/// Voice audio and controls never use BLE; they switch to Wi-Fi after setup.
final class WirelessProvisioningService: NSObject, ObservableObject {
    @Published private(set) var statusText = "Looking for a wireless board…"
    @Published private(set) var boardName: String?
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var nearbyDevices: [NearbyWirelessDevice] = []
    @Published private(set) var selectedPeripheralID: UUID?
    @Published private(set) var selectedIdentity: WirelessProvisioningIdentity?
    @Published private(set) var pairedDeviceID: String?
    @Published private(set) var phase: WirelessProvisioningPhase = .idle
    @Published private(set) var lastError: DeviceActionError?
    @Published private(set) var bleLinkState: WirelessBLELinkState = .unavailable

    private static let serviceUUID = CBUUID(
        string: "7A9E0001-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let ssidUUID = CBUUID(
        string: "7A9E0002-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let passwordUUID = CBUUID(
        string: "7A9E0003-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let applyUUID = CBUUID(
        string: "7A9E0004-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let statusUUID = CBUUID(
        string: "7A9E0005-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let pairUUID = CBUUID(
        string: "7A9E0006-7C4B-4F76-B462-37A6DE9CC5B1"
    )
    private static let infoUUID = CBUUID(
        string: "7A9E0007-7C4B-4F76-B462-37A6DE9CC5B1"
    )

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var queuedCredentials: Credentials?
    private var currentWrite: WriteStep?
    private var scanRequested = false
    private var configuredSuccessfully = false
    private var bindingPersistedSuccessfully = false
    private var publicDeviceInfo: PublicDeviceInfo?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private let credentialStore = WirelessCredentialStore.shared
    private let logger = Logger(
        subsystem: "com.voiceops.VoiceOps",
        category: "WirelessProvisioning"
    )

    private struct Credentials {
        var ssid: Data
        var password: Data
        var pairingCode: String
        var configureWiFi: Bool
    }

    private enum WriteStep {
        case pair
        case ssid
        case password
        case apply
    }

    private struct PublicDeviceInfo: Decodable {
        let deviceID: String
        let nickname: String
        let model: String
        let devicePublicKey: String
        let bindingEpoch: UInt32

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case nickname
            case model
            case devicePublicKey = "device_public_key"
            case bindingEpoch = "binding_epoch"
        }
    }

    private struct PairRequest: Encodable {
        let pairCode: String
        let clientID: String
        let appID: String
        let clientPublicKey: String

        enum CodingKeys: String, CodingKey {
            case pairCode = "pair_code"
            case clientID = "client_id"
            case appID = "app_id"
            case clientPublicKey = "client_public_key"
        }
    }

    private struct PairResponse: Decodable {
        let ok: Bool
        let role: VoiceProviderRole?
        let error: String?
    }

    func startScanning() {
        scanRequested = true
        if peripheral == nil {
            phase = .scanning
            statusText = "Choose the StopWatch you want to add."
            if central.state == .poweredOn {
                bleLinkState = .scanning
            }
        }
        _ = central
        beginScanIfPossible()
    }

    func stopScanning() {
        scanRequested = false
        central.stopScan()
        cancelConnectionTimeout()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
    }

    func selectDevice(id: UUID) {
        guard !isBusy, let candidate = discoveredPeripherals[id] else {
            fail(
                "That BLE device is no longer visible. Scan again.",
                code: .deviceNotFound,
                stage: .discovered,
                recovery: .rescan
            )
            return
        }
        if let peripheral, peripheral.identifier != id {
            central.cancelPeripheralConnection(peripheral)
        }
        selectedPeripheralID = id
        selectedIdentity = nil
        publicDeviceInfo = nil
        characteristics.removeAll()
        connect(candidate)
    }

    func cancelSelection() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        selectedPeripheralID = nil
        selectedIdentity = nil
        publicDeviceInfo = nil
        pairedDeviceID = nil
        characteristics.removeAll()
        queuedCredentials = nil
        currentWrite = nil
        configuredSuccessfully = false
        bindingPersistedSuccessfully = false
        cancelConnectionTimeout()
        isBusy = false
        isReady = false
        lastError = nil
        phase = .scanning
        bleLinkState = central.state == .poweredOn ? .scanning : .unavailable
        statusText = "Choose the StopWatch you want to add."
        startScanning()
    }

    func retryAfterFailure() {
        lastError = nil
        if let deviceID = pairedDeviceID, bindingPersistedSuccessfully {
            isBusy = true
            bleLinkState = .wifiHandoff
            phase = .awaitingBonjour(deviceID)
            statusText = "Retrying the secure Wi-Fi connection…"
            Task { @MainActor in
                await DeviceManager.shared.connect(deviceID: deviceID)
            }
            return
        }
        if peripheral != nil, selectedIdentity != nil {
            confirmPhysicalIdentity()
        } else {
            cancelSelection()
        }
    }

    func reportAuthenticationFailure(_ error: DeviceActionError) {
        guard let pairedDeviceID,
              error.stage == .authenticating,
              error.code != .deviceNotFound else { return }
        isBusy = false
        isReady = false
        lastError = error
        phase = .failed(error)
        statusText = "Authentication failed for \(pairedDeviceID)."
    }

    func confirmPhysicalIdentity() {
        guard let deviceID = selectedIdentity?.deviceID else { return }
        phase = .awaitingPhysicalConfirmation(deviceID)
        statusText = "Long-press the device button, then enter the six-digit code shown on its screen."
    }

    func markAuthenticating(deviceID: String) {
        guard pairedDeviceID == deviceID else { return }
        phase = .authenticating(deviceID)
        statusText = "Found the same device on Wi-Fi. Authenticating…"
    }

    func markAuthenticated(deviceID: String) {
        guard pairedDeviceID == deviceID else { return }
        phase = .complete(deviceID)
        bleLinkState = .wifiHandoff
        isReady = true
        isBusy = false
        statusText = "Secure setup is complete. \(deviceID) is ready."
    }

    @discardableResult
    func configure(ssid: String, password: String, pairingCode: String) -> Bool {
        let ssidData = Data(ssid.utf8)
        let passwordData = Data(password.utf8)
        guard !ssidData.isEmpty, ssidData.count <= 32 else {
            statusText = "Wi-Fi name must be 1–32 bytes."
            return false
        }
        guard passwordData.count <= 63 else {
            statusText = "Wi-Fi password must be at most 63 bytes."
            return false
        }
        guard pairingCode.count == 6, pairingCode.allSatisfy(\.isNumber) else {
            statusText = "Enter the six-digit code shown on the StopWatch."
            return false
        }

        queuedCredentials = Credentials(
            ssid: ssidData,
            password: passwordData,
            pairingCode: pairingCode,
            configureWiFi: true
        )
        configuredSuccessfully = false
        bindingPersistedSuccessfully = false
        isBusy = true
        lastError = nil
        if let deviceID = selectedIdentity?.deviceID {
            phase = .securePairing(deviceID)
        }
        if hasProvisioningCharacteristics {
            beginCredentialWrite()
        } else {
            statusText = "Connecting to the wireless board…"
            startScanning()
        }
        return true
    }

    /// Adds this Mac to a StopWatch that is already on Wi-Fi. Later clients
    /// default to controller and therefore cannot rewrite network settings.
    @discardableResult
    func pair(pairingCode: String) -> Bool {
        guard pairingCode.count == 6, pairingCode.allSatisfy(\.isNumber) else {
            statusText = "Enter the six-digit code shown on the StopWatch."
            return false
        }
        queuedCredentials = Credentials(
            ssid: Data(),
            password: Data(),
            pairingCode: pairingCode,
            configureWiFi: false
        )
        configuredSuccessfully = false
        bindingPersistedSuccessfully = false
        isBusy = true
        lastError = nil
        if let deviceID = selectedIdentity?.deviceID {
            phase = .securePairing(deviceID)
        }
        if hasProvisioningCharacteristics {
            beginCredentialWrite()
        } else {
            statusText = "Connecting to the wireless board…"
            startScanning()
        }
        return true
    }

    private var hasProvisioningCharacteristics: Bool {
        characteristics[Self.ssidUUID] != nil &&
        characteristics[Self.passwordUUID] != nil &&
        characteristics[Self.applyUUID] != nil &&
        characteristics[Self.pairUUID] != nil &&
        characteristics[Self.infoUUID] != nil
    }

    private func beginScanIfPossible() {
        guard scanRequested, central.state == .poweredOn,
              peripheral == nil else { return }
        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.serviceUUID]
        )
        for candidate in connected {
            discoveredPeripherals[candidate.identifier] = candidate
            upsertNearby(candidate, rssi: 0)
        }
        statusText = "Looking for a wireless board…"
        bleLinkState = .scanning
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func connect(_ candidate: CBPeripheral) {
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        boardName = candidate.name
        isReady = false
        phase = .connecting(candidate.identifier)
        bleLinkState = .connecting
        statusText = "Connecting to \(candidate.name ?? "wireless board")…"
        scheduleConnectionTimeout(for: candidate)
        logger.info("Starting BLE connection to selected StopWatch")
        if candidate.state == .connected {
            cancelConnectionTimeout()
            bleLinkState = .connected
            candidate.discoverServices([Self.serviceUUID])
        } else {
            central.connect(candidate)
        }
    }

    private func upsertNearby(_ candidate: CBPeripheral, rssi: Int) {
        let id = candidate.identifier
        let existing = nearbyDevices.first(where: { $0.id == id })
        let entry = NearbyWirelessDevice(
            id: id,
            displayName: candidate.name ?? existing?.displayName ?? "inVoice StopWatch",
            rssi: rssi == 0 ? (existing?.rssi ?? 0) : rssi,
            deviceID: existing?.deviceID ?? advertisedDeviceID(candidate.name),
            nickname: existing?.nickname,
            model: existing?.model
        )
        if let index = nearbyDevices.firstIndex(where: { $0.id == id }) {
            nearbyDevices[index] = entry
        } else {
            nearbyDevices.append(entry)
        }
        nearbyDevices.sort {
            if $0.rssi == $1.rssi { return $0.id.uuidString < $1.id.uuidString }
            return $0.rssi > $1.rssi
        }
    }

    private func advertisedDeviceID(_ name: String?) -> String? {
        guard let name else { return nil }
        let lowercased = name.lowercased()
        guard lowercased.hasPrefix("mlxvoice-") ||
                lowercased.hasPrefix("invoice-") else { return nil }
        guard let suffix = name.split(separator: "-").last else { return nil }
        let shortID = suffix.uppercased()
        guard shortID.count == 6,
              shortID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "MV-\(shortID)"
    }

    private func scheduleConnectionTimeout(for candidate: CBPeripheral) {
        cancelConnectionTimeout()
        let candidateID = candidate.identifier
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.peripheral?.identifier == candidateID,
                  candidate.state != .connected else { return }
            self.logger.error("BLE connection timed out")
            self.central.cancelPeripheralConnection(candidate)
            self.peripheral = nil
            self.characteristics.removeAll()
            self.bleLinkState = .failed
            self.fail(
                "Bluetooth did not connect within 12 seconds. Keep the StopWatch awake and try again.",
                code: .deviceNotFound,
                stage: .discovered,
                recovery: .rescan
            )
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    private func beginCredentialWrite() {
        guard let peripheral, let credentials = queuedCredentials,
              let characteristic = characteristics[Self.pairUUID],
              publicDeviceInfo != nil else { return }
        do {
            let identity = try credentialStore.clientIdentity()
            guard let publicKey = identity.publicKeyBase64 else {
                throw WirelessCredentialStoreError.invalidIdentity
            }
            let request = PairRequest(
                pairCode: credentials.pairingCode,
                clientID: identity.clientID.uuidString.lowercased(),
                appID: identity.appID,
                clientPublicKey: publicKey
            )
            statusText = "Pairing with the confirmed physical device…"
            currentWrite = .pair
            peripheral.writeValue(
                try JSONEncoder().encode(request),
                for: characteristic,
                type: .withResponse
            )
        } catch {
            fail("Could not create the Mac identity: \(error.localizedDescription)")
        }
    }

    private func writeSSID() {
        guard let peripheral, let credentials = queuedCredentials,
              let characteristic = characteristics[Self.ssidUUID] else {
            fail("The Wi-Fi characteristic is unavailable.")
            return
        }
        currentWrite = .ssid
        peripheral.writeValue(credentials.ssid, for: characteristic, type: .withResponse)
    }

    private func writePassword() {
        guard let peripheral, let credentials = queuedCredentials,
              let characteristic = characteristics[Self.passwordUUID] else {
            fail("The password characteristic is unavailable.")
            return
        }
        currentWrite = .password
        peripheral.writeValue(
            credentials.password,
            for: characteristic,
            type: .withResponse
        )
    }

    private func writeApply() {
        guard let peripheral,
              let characteristic = characteristics[Self.applyUUID] else {
            fail("The apply characteristic is unavailable.")
            return
        }
        currentWrite = .apply
        peripheral.writeValue(
            Data("apply".utf8),
            for: characteristic,
            type: .withResponse
        )
    }

    private func completeConfiguration() {
        configuredSuccessfully = true
        queuedCredentials = nil
        currentWrite = nil
        isBusy = false
        isReady = false
        bleLinkState = .wifiHandoff
        if let deviceID = pairedDeviceID ?? selectedIdentity?.deviceID {
            phase = .awaitingBonjour(deviceID)
            statusText = "Wi-Fi saved. Waiting for the same device to appear through Bonjour…"
        }
    }

    private func completePairing(deviceID: String) {
        queuedCredentials = nil
        currentWrite = nil
        isBusy = true
        isReady = false
        bleLinkState = .wifiHandoff
        phase = .awaitingBonjour(deviceID)
        statusText = "Pairing saved. Finding the same device through Bonjour…"
    }

    private func fail(
        _ message: String,
        code: VoiceProviderErrorCode = .invalidMessage,
        stage: DeviceJourneyStage = .securePairing,
        recovery: DeviceRecoveryAction = .retry
    ) {
        queuedCredentials = nil
        currentWrite = nil
        isBusy = false
        statusText = message
        let error = DeviceActionError(
            stage: stage,
            code: code,
            message: message,
            recovery: recovery
        )
        lastError = error
        phase = .failed(error)
        bleLinkState = .failed
    }
}

extension WirelessProvisioningService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bleLinkState = peripheral == nil ? .scanning : bleLinkState
            if peripheral == nil { phase = .scanning }
            beginScanIfPossible()
        case .poweredOff:
            bleLinkState = .unavailable
            fail(
                "Turn on Bluetooth to configure the wireless board.",
                code: .deviceNotFound,
                stage: .discovered,
                recovery: .rescan
            )
        case .unauthorized:
            bleLinkState = .unavailable
            fail(
                "Allow Bluetooth access for inVoice in System Settings.",
                code: .unauthorized,
                stage: .discovered,
                recovery: .rescan
            )
        case .unsupported:
            bleLinkState = .unavailable
            fail(
                "Bluetooth Low Energy is unavailable on this Mac.",
                code: .deviceNotFound,
                stage: .discovered,
                recovery: .rescan
            )
        case .resetting, .unknown:
            bleLinkState = .unavailable
            statusText = "Waiting for Bluetooth…"
            isReady = false
        @unknown default:
            bleLinkState = .unavailable
            statusText = "Bluetooth is unavailable."
            isReady = false
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        upsertNearby(peripheral, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        cancelConnectionTimeout()
        bleLinkState = .connected
        statusText = "Reading wireless board capabilities…"
        logger.info("BLE connected; discovering setup service")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        cancelConnectionTimeout()
        self.peripheral = nil
        characteristics.removeAll()
        isReady = false
        selectedPeripheralID = nil
        bleLinkState = .failed
        logger.error("BLE connection failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        fail(
            "Could not connect. Keep the board on its setup screen and try again.",
            code: .deviceNotFound,
            stage: .discovered,
            recovery: .rescan
        )
        beginScanIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        cancelConnectionTimeout()
        self.peripheral = nil
        characteristics.removeAll()
        isReady = false
        if configuredSuccessfully || bindingPersistedSuccessfully {
            bleLinkState = .wifiHandoff
            if let deviceID = pairedDeviceID {
                phase = .awaitingBonjour(deviceID)
            }
            statusText = configuredSuccessfully
                ? "Wi-Fi saved. Waiting for the board to join the network…"
                : "Pairing saved. Waiting for the secure Wi-Fi connection…"
            return
        }
        if isBusy {
            fail(
                "The board disconnected before setup completed. Please try again.",
                code: .deviceNotFound,
                recovery: .retry
            )
        } else {
            phase = .scanning
            bleLinkState = .scanning
            statusText = "Wireless board disconnected. Choose it again to continue."
        }
        beginScanIfPossible()
    }
}

extension WirelessProvisioningService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail("Could not read board services: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == Self.serviceUUID
        }) else {
            fail("This board does not expose the inVoice setup service.")
            return
        }
        peripheral.discoverCharacteristics(
            [
                Self.ssidUUID, Self.passwordUUID, Self.applyUUID,
                Self.statusUUID, Self.pairUUID, Self.infoUUID,
            ],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            fail("Could not read board settings: \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        guard hasProvisioningCharacteristics else {
            fail("The board firmware does not support secure Wi-Fi setup.")
            return
        }
        if let status = characteristics[Self.statusUUID] {
            peripheral.setNotifyValue(true, for: status)
        }
        guard let info = characteristics[Self.infoUUID] else { return }
        statusText = "Reading the physical device identity…"
        peripheral.readValue(for: info)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            fail("Secure setup failed: \(error.localizedDescription)")
            return
        }
        switch currentWrite {
        case .pair:
            peripheral.readValue(for: characteristic)
        case .ssid:
            writePassword()
        case .password:
            writeApply()
        case .apply:
            completeConfiguration()
        case nil:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              let value = characteristic.value else { return }
        if characteristic.uuid == Self.infoUUID {
            do {
                let info = try JSONDecoder().decode(PublicDeviceInfo.self, from: value)
                guard info.deviceID.hasPrefix("MV-"),
                      Data(base64Encoded: info.devicePublicKey)?.count == 65 else {
                    throw WirelessCredentialStoreError.invalidDeviceKey
                }
                publicDeviceInfo = info
                boardName = "\(info.nickname) (\(info.deviceID))"
                selectedIdentity = WirelessProvisioningIdentity(
                    deviceID: info.deviceID,
                    nickname: info.nickname,
                    model: info.model,
                    bindingEpoch: info.bindingEpoch
                )
                if let selectedPeripheralID,
                   let index = nearbyDevices.firstIndex(where: { $0.id == selectedPeripheralID }) {
                    nearbyDevices[index].deviceID = info.deviceID
                    nearbyDevices[index].nickname = info.nickname
                    nearbyDevices[index].model = info.model
                }
                isReady = true
                bleLinkState = .identityVerified
                logger.info("BLE identity verified for selected StopWatch")
                if queuedCredentials != nil {
                    beginCredentialWrite()
                } else {
                    phase = .confirmingIdentity(info.deviceID)
                    statusText = "Confirm that the short ID matches the physical device."
                }
            } catch {
                fail("The board returned an invalid identity.")
            }
            return
        }
        if characteristic.uuid == Self.pairUUID {
            do {
                let response = try JSONDecoder().decode(PairResponse.self, from: value)
                guard response.ok else {
                    let code = response.error.flatMap(VoiceProviderErrorCode.init(rawValue:))
                        ?? .invalidPairCode
                    fail(
                        response.error ?? "Pairing was rejected by the board.",
                        code: code,
                        recovery: code == .pairCodeExpired
                            ? .enterPairingMode
                            : .reenterPairingCode
                    )
                    return
                }
                guard let role = response.role,
                      let info = publicDeviceInfo,
                      let publicKey = Data(base64Encoded: info.devicePublicKey) else {
                    fail("The board returned incomplete pairing credentials.")
                    return
                }
                let binding = WirelessDeviceBinding(
                    deviceID: info.deviceID,
                    nickname: info.nickname,
                    model: info.model,
                    devicePublicKey: publicKey,
                    role: role,
                    bindingEpoch: info.bindingEpoch
                )
                try credentialStore.save(binding: binding)
                let clientID = try credentialStore.clientIdentity().clientID
                bindingPersistedSuccessfully = true
                pairedDeviceID = info.deviceID
                bleLinkState = .bindingSecured
                let shouldConfigureWiFi = queuedCredentials?.configureWiFi == true
                logger.info("BLE pairing completed; switching to Wi-Fi")
                Task { @MainActor in
                    WirelessDeviceCatalog.shared.record(
                        binding: binding,
                        clientID: clientID
                    )
                    DeviceManager.shared.recordBLEIdentity(
                        deviceID: info.deviceID,
                        nickname: info.nickname,
                        model: info.model,
                        bindingEpoch: info.bindingEpoch
                    )
                    DeviceManager.shared.pairingDidPersist(deviceID: info.deviceID)
                    if !shouldConfigureWiFi {
                        await DeviceManager.shared.connect(deviceID: info.deviceID)
                    }
                }
                if shouldConfigureWiFi {
                    phase = .provisioningWiFi(info.deviceID)
                    writeSSID()
                } else {
                    completePairing(deviceID: info.deviceID)
                }
            } catch {
                fail("The board returned an invalid pairing response.")
            }
            return
        }
        guard characteristic.uuid == Self.statusUUID,
              let status = String(data: value, encoding: .utf8) else { return }
        if status == "saved" {
            completeConfiguration()
        } else if status == "save-failed" {
            fail("The board could not save its Wi-Fi settings.")
        }
    }
}
