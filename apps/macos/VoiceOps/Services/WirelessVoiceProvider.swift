import CryptoKit
import Foundation

/// Additive LAN provider for the M5Stack StopWatch. It deliberately owns no
/// USB behavior: the existing CoreAudio/HID path remains in AudioCaptureService
/// and FnKeyMonitor and is represented by `USBProvider` below.
@MainActor
final class WirelessVoiceProvider: NSObject, VoiceDeviceManaging {
    static let shared = WirelessVoiceProvider()

    enum ConnectionState: Equatable {
        case searching
        case connecting(String)
        case authenticating(String)
        case connected(String)
        case busy(deviceID: String, clientID: String?)
        case disconnected
    }

    let kind = VoiceInputProvider.wirelessStopWatch

    var onPTTChanged: ((Bool) -> Void)?
    var onAudioPacket: ((WirelessVoiceAudioPacket) -> Void)?
    var onControl: ((String) -> Void)?
    var onConnectionState: ((ConnectionState) -> Void)?
    var onDevicesChanged: (([VoiceProviderDevice]) -> Void)?
    var onAudioStateChanged: ((DeviceAudioState) -> Void)?

    private let browser = NetServiceBrowser()
    private lazy var session = URLSession(configuration: .default)
    private let credentialStore = WirelessCredentialStore.shared
    private var services: [String: NetService] = [:]
    private var serviceDeviceIDs: [String: String] = [:]
    private var endpoints: [String: URL] = [:]
    private var directory = WirelessDeviceDirectory()
    private var socket: URLSessionWebSocketTask?
    private var endpointURL: URL?
    private var selectedDeviceID: String?
    private var currentClientID: String?
    private var authenticatedRole: VoiceProviderRole?
    private var sessionID = UUID()
    private var socketGeneration = UUID()
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingTimer: Timer?
    private var lastSocketActivityAt: Date?
    private var lastPTT = false
    private var remotePTTPressed = false
    private var running = false
    private var activeLease: VoiceAudioLease?
    private var leaseContinuation: CheckedContinuation<VoiceAudioLease?, Error>?
    private var revokeContinuation: CheckedContinuation<Void, Error>?
    private var statusCache: VoiceProviderDeviceStatus?
    private var recentDeviceMessageIDs: [String] = []
    private var recentAudioMessageIDs: [Data] = []
    private var latestDeviceTimestamp: Int64 = 0

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !running else { return }
        running = true
        onConnectionState?(.searching)
        browser.searchForServices(
            ofType: WirelessProtocolV2.serviceType,
            inDomain: WirelessProtocolV2.serviceDomain
        )
    }

    func stop() {
        running = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pingTimer?.invalidate()
        pingTimer = nil
        browser.stop()
        for service in services.values {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        serviceDeviceIDs.removeAll()
        endpoints.removeAll()
        endpointURL = nil
        tearDownSocket(notifyRelease: true)
        onConnectionState?(.disconnected)
    }

    // MARK: VoiceProvider

    func discover() async throws -> [VoiceProviderDevice] {
        start()
        return directory.devices
    }

    func connect(deviceID: String?) async throws {
        start()
        let catalog = WirelessDeviceCatalog.shared
        let bindings = Array(catalog.bindings.values)
        let target = deviceID
            ?? UserDefaults.standard.string(forKey: "wireless.defaultDeviceID")
            ?? (bindings.count == 1 ? bindings.first?.deviceID : nil)
        guard let target else { throw VoiceProviderErrorCode.deviceNotFound }
        guard catalog.binding(deviceID: target) != nil else {
            throw VoiceProviderErrorCode.unauthorized
        }
        selectedDeviceID = target
        guard let endpoint = endpoints[target] else {
            onConnectionState?(.searching)
            throw VoiceProviderErrorCode.deviceNotFound
        }
        connectSocket(to: endpoint, deviceID: target)
    }

    func disconnect() async {
        selectedDeviceID = nil
        endpointURL = nil
        tearDownSocket(notifyRelease: true)
        onConnectionState?(.disconnected)
    }

    func startAudio() async throws -> VoiceAudioLease? {
        guard authenticatedRole?.allows(.audio) == true else {
            throw VoiceProviderErrorCode.unauthorized
        }
        if let activeLease, activeLease.expiresAt > Date() { return activeLease }
        guard leaseContinuation == nil else { throw VoiceProviderErrorCode.deviceBusy }
        try sendSigned(type: .acquireAudioLease, payload: ["force": "false"])
        return try await withCheckedThrowingContinuation { continuation in
            leaseContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let pending = self.leaseContinuation else { return }
                self.leaseContinuation = nil
                pending.resume(throwing: VoiceProviderErrorCode.deviceNotFound)
            }
        }
    }

    func stopAudio() async {
        guard let lease = activeLease else { return }
        try? sendSigned(type: .releaseAudioLease, payload: [
            "lease_id": lease.leaseID.uuidString.lowercased(),
        ])
        activeLease = nil
        statusCache?.activeLease = nil
        if let statusCache {
            WirelessDeviceCatalog.shared.update(status: statusCache)
        }
        onAudioStateChanged?(.idle)
    }

    func sendControl(_ control: VoiceProviderControl) async throws {
        let payload: [String: String]
        let type: WirelessMessageType
        switch control {
        case .clipboard:
            type = .control
            payload = ["name": "clipboard"]
        case .setNickname(let nickname):
            type = .control
            payload = ["name": "set_nickname", "nickname": nickname]
        case .revokeClient(let clientID):
            type = .revokeClient
            payload = ["target_client_id": clientID.uuidString.lowercased()]
        case .transferOwnership(let clientID, let retain):
            type = .transferOwnership
            payload = [
                "target_client_id": clientID.uuidString.lowercased(),
                "retain_previous_owner": String(retain),
            ]
        case .forceReleaseAudio:
            type = .releaseAudioLease
            payload = ["force": "true", "lease_id": activeLease?.leaseID.uuidString ?? ""]
        case .forceRebind:
            type = .forceRebind
            payload = [:]
        case .factoryReset:
            type = .factoryReset
            payload = [:]
        }
        try sendSigned(type: type, payload: payload)
    }

    func getStatus() async throws -> VoiceProviderDeviceStatus {
        guard let statusCache else { throw VoiceProviderErrorCode.deviceNotFound }
        try sendSigned(type: .deviceStatus)
        return statusCache
    }

    func updateFirmware(_ image: Data) async throws {
        guard authenticatedRole?.allows(.updateFirmware) == true,
              let deviceID = selectedDeviceID,
              let endpointURL else {
            throw VoiceProviderErrorCode.otaNotAllowed
        }
        let digest = Data(SHA256.hash(data: image)).base64EncodedString()
        let authorization = try makeSignedMessage(type: .otaStart, payload: [
            "sha256": digest,
            "size": String(image.count),
        ])
        guard let signature = authorization.signature else {
            throw VoiceProviderErrorCode.unauthorized
        }
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        components?.path = "/v2/ota"
        guard let url = components?.url else { throw VoiceProviderErrorCode.deviceNotFound }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = image
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-MLX-Device-ID")
        request.setValue(authorization.header.clientID, forHTTPHeaderField: "X-MLX-Client-ID")
        request.setValue(authorization.header.sessionID, forHTTPHeaderField: "X-MLX-Session-ID")
        request.setValue(authorization.header.messageID, forHTTPHeaderField: "X-MLX-Message-ID")
        request.setValue(String(authorization.header.timestamp), forHTTPHeaderField: "X-MLX-Timestamp")
        request.setValue(digest, forHTTPHeaderField: "X-MLX-SHA256")
        request.setValue(signature, forHTTPHeaderField: "X-MLX-Signature")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw VoiceProviderErrorCode.otaNotAllowed
        }
    }

    func unbind(deviceID: String) async throws {
        guard selectedDeviceID == deviceID, socket != nil,
              authenticatedRole == .owner else {
            throw VoiceProviderErrorCode.unauthorized
        }
        let identity = try credentialStore.clientIdentity()
        try await withCheckedThrowingContinuation { continuation in
            revokeContinuation = continuation
            do {
                try sendSigned(type: .revokeClient, payload: [
                    "target_client_id": identity.clientID.uuidString.lowercased(),
                ])
            } catch {
                revokeContinuation = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let pending = self.revokeContinuation else { return }
                self.revokeContinuation = nil
                pending.resume(throwing: VoiceProviderErrorCode.deviceNotFound)
            }
        }
        try credentialStore.removeBinding(deviceID: deviceID)
        if UserDefaults.standard.string(forKey: "wireless.defaultDeviceID") == deviceID {
            UserDefaults.standard.removeObject(forKey: "wireless.defaultDeviceID")
            WirelessDeviceCatalog.shared.defaultDeviceID = nil
        }
        WirelessDeviceCatalog.shared.refresh()
        Task { await disconnect() }
    }

    // MARK: Discovery and session

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func connectSocket(to url: URL, deviceID: String) {
        guard running, selectedDeviceID == deviceID else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        tearDownSocket(notifyRelease: true)
        endpointURL = url
        sessionID = UUID()
        socketGeneration = UUID()
        let generation = socketGeneration
        guard let identity = try? credentialStore.clientIdentity() else {
            onConnectionState?(.disconnected)
            return
        }
        currentClientID = identity.clientID.uuidString.lowercased()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: identity.clientID.uuidString.lowercased()),
            URLQueryItem(name: "session_id", value: sessionID.uuidString.lowercased()),
        ]
        guard let sessionURL = components?.url else {
            onConnectionState?(.disconnected)
            return
        }
        let task = session.webSocketTask(with: sessionURL)
        socket = task
        lastSocketActivityAt = Date()
        onConnectionState?(.connecting(deviceID))
        task.resume()
        receiveNext(from: task, generation: generation)
        startPingTimer(for: task, generation: generation)
    }

    private func receiveNext(from task: URLSessionWebSocketTask, generation: UUID) {
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self, let task, self.running, self.socket === task,
                      self.socketGeneration == generation else { return }
                switch result {
                case .success(let message):
                    self.lastSocketActivityAt = Date()
                    self.handle(message)
                    self.receiveNext(from: task, generation: generation)
                case .failure(let error):
                    NSLog("VoiceOps: wireless provider disconnected: %@", String(describing: error))
                    self.connectionFailed(generation: generation)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            guard activeLease != nil else { return }
            do {
                let packet = try WirelessVoiceAudioPacket(data: data)
                guard packet.protocolVersion == WirelessProtocolV2.version,
                      packet.deviceID == selectedDeviceID,
                      packet.clientID == currentClientID,
                      packet.sessionID == sessionID.uuidString.lowercased(),
                      let messageID = packet.messageID,
                      !recentAudioMessageIDs.contains(messageID) else { return }
                recentAudioMessageIDs.append(messageID)
                if recentAudioMessageIDs.count > 128 {
                    recentAudioMessageIDs.removeFirst(
                        recentAudioMessageIDs.count - 128
                    )
                }
                onAudioPacket?(packet)
            } catch {
                NSLog("VoiceOps: ignored malformed wireless audio packet: %@", String(describing: error))
            }
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(WirelessProtocolMessage.self, from: data),
                  event.header.deviceID == selectedDeviceID,
                  event.header.clientID == currentClientID,
                  event.header.sessionID == sessionID.uuidString.lowercased(),
                  event.header.timestamp >= latestDeviceTimestamp,
                  !recentDeviceMessageIDs.contains(event.header.messageID),
                  let signatureText = event.signature,
                  let signature = Data(base64Encoded: signatureText),
                  (try? credentialStore.verifyDeviceSignature(
                    signature,
                    data: event.signingBytes(),
                    deviceID: event.header.deviceID
                  )) == true else { return }
            latestDeviceTimestamp = event.header.timestamp
            recentDeviceMessageIDs.append(event.header.messageID)
            if recentDeviceMessageIDs.count > 128 {
                recentDeviceMessageIDs.removeFirst(
                    recentDeviceMessageIDs.count - 128
                )
            }
            handle(event)
        @unknown default:
            break
        }
    }

    private func handle(_ event: WirelessProtocolMessage) {
        switch event.header.messageType {
        case .authenticateChallenge:
            authenticate(challenge: event)
        case .authenticated:
            guard let roleRaw = event.payload["role"],
                  let role = VoiceProviderRole(rawValue: roleRaw),
                  let deviceID = selectedDeviceID else { return }
            authenticatedRole = role
            if let device = directory.device(id: deviceID) {
                let status = VoiceProviderDeviceStatus(
                    device: device,
                    batteryPercent: nil,
                    role: role,
                    activeLease: nil,
                    activeLeaseAppID: nil
                )
                statusCache = status
                WirelessDeviceCatalog.shared.update(status: status)
            }
            onConnectionState?(.connected(deviceID))
        case .pttDown:
            guard authenticatedRole?.allows(.audio) == true else { return }
            remotePTTPressed = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard try await self.startAudio() != nil else { return }
                    // A short physical tap may be released before the lease
                    // response returns. Never start a stuck recording from a
                    // stale ptt_down; release the newly acquired lease instead.
                    if self.remotePTTPressed {
                        self.publishPTT(true)
                    } else {
                        await self.stopAudio()
                    }
                } catch VoiceProviderErrorCode.deviceBusy {
                    return
                } catch {
                    NSLog("VoiceOps: audio lease rejected: %@", String(describing: error))
                }
            }
        case .pttUp:
            remotePTTPressed = false
            publishPTT(false)
            Task { [weak self] in await self?.stopAudio() }
        case .audioLeaseAcquired:
            completeLease(event)
        case .control:
            if authenticatedRole?.allows(.control) == true,
               let name = event.payload["name"] {
                onControl?(name)
            }
        case .deviceStatus:
            updateStatus(event)
        case .revokeClient:
            let continuation = revokeContinuation
            revokeContinuation = nil
            continuation?.resume()
        case .error:
            handleError(event)
        default:
            break
        }
    }

    private func authenticate(challenge: WirelessProtocolMessage) {
        guard let deviceID = selectedDeviceID,
              challenge.header.deviceID == deviceID,
              let signatureText = challenge.signature,
              let signature = Data(base64Encoded: signatureText),
              (try? credentialStore.verifyDeviceSignature(
                signature,
                data: challenge.signingBytes(),
                deviceID: deviceID
              )) == true,
              let nonce = challenge.payload["nonce"],
              let epochText = challenge.payload["binding_epoch"],
              let epoch = UInt32(epochText),
              let binding = try? credentialStore.binding(deviceID: deviceID),
              binding.bindingEpoch == epoch else {
            connectionFailed(generation: socketGeneration)
            return
        }
        onConnectionState?(.authenticating(deviceID))
        try? sendSigned(type: .authenticate, payload: [
            "nonce": nonce,
            "app_id": "invoice",
            "binding_epoch": String(epoch),
        ])
    }

    private func completeLease(_ event: WirelessProtocolMessage) {
        guard let deviceID = selectedDeviceID,
              let identity = try? credentialStore.clientIdentity(),
              let leaseText = event.payload["lease_id"],
              let leaseID = UUID(uuidString: leaseText),
              let ttlText = event.payload["ttl_ms"],
              let ttlMS = Double(ttlText) else { return }
        let lease = VoiceAudioLease(
            leaseID: leaseID,
            deviceID: deviceID,
            clientID: identity.clientID,
            sessionID: sessionID,
            acquiredAt: Date(),
            expiresAt: Date().addingTimeInterval(ttlMS / 1_000)
        )
        activeLease = lease
        statusCache?.activeLease = lease
        if let statusCache {
            WirelessDeviceCatalog.shared.update(status: statusCache)
        }
        onAudioStateChanged?(.leased)
        let continuation = leaseContinuation
        leaseContinuation = nil
        continuation?.resume(returning: lease)
    }

    private func updateStatus(_ event: WirelessProtocolMessage) {
        if let battery = event.payload["battery_percent"].flatMap(UInt8.init) {
            statusCache?.batteryPercent = battery
        }
        statusCache?.activeLeaseAppID = event.payload["lease_app_id"]
        if let statusCache {
            WirelessDeviceCatalog.shared.update(status: statusCache)
        }
    }

    private func handleError(_ event: WirelessProtocolMessage) {
        let error = event.payload["code"].flatMap(VoiceProviderErrorCode.init(rawValue:))
            ?? .invalidMessage
        if error == .deviceBusy, let deviceID = selectedDeviceID {
            onConnectionState?(.busy(
                deviceID: deviceID,
                clientID: event.payload["occupant_client_id"]
            ))
            onAudioStateChanged?(.busy(
                appID: event.payload["occupant_app_id"],
                clientID: event.payload["occupant_client_id"]
            ))
        } else if error == .leaseExpired {
            onAudioStateChanged?(.expired)
        }
        let continuation = leaseContinuation
        leaseContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func makeSignedMessage(
        type: WirelessMessageType,
        payload: [String: String] = [:]
    ) throws -> WirelessProtocolMessage {
        guard let deviceID = selectedDeviceID else {
            throw VoiceProviderErrorCode.deviceNotFound
        }
        let identity = try credentialStore.clientIdentity()
        var message = WirelessProtocolMessage(
            header: WirelessProtocolHeader(
                deviceID: deviceID,
                clientID: identity.clientID.uuidString.lowercased(),
                sessionID: sessionID.uuidString.lowercased(),
                messageType: type
            ),
            payload: payload
        )
        message.signature = try credentialStore.sign(message.signingBytes()).base64EncodedString()
        return message
    }

    private func sendSigned(
        type: WirelessMessageType,
        payload: [String: String] = [:]
    ) throws {
        guard let socket else { throw VoiceProviderErrorCode.deviceNotFound }
        let generation = socketGeneration
        let message = try makeSignedMessage(type: type, payload: payload)
        let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                NSLog("VoiceOps: wireless send failed: %@", String(describing: error))
                guard let self else { return }
                // The callback can arrive after a newer socket is already
                // active. Attribute failure to the socket that performed the
                // send so a stale completion cannot tear down that new socket.
                self.connectionFailed(generation: generation)
            }
        }
    }

    private func publishPTT(_ pressed: Bool) {
        guard pressed != lastPTT else { return }
        lastPTT = pressed
        onPTTChanged?(pressed)
    }

    private func startPingTimer(for task: URLSessionWebSocketTask, generation: UUID) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: WirelessProtocolV2.heartbeatInterval, repeats: true) {
            [weak self, weak task] _ in
            guard let self, let task else { return }
            Task { @MainActor in
                guard self.running, self.socket === task,
                      self.socketGeneration == generation else { return }
                // URLSession can leave receive/sendPing callbacks pending after
                // a peer-side close. Bound that silent half-open state so the
                // UI and audio lease cannot remain attached to a dead socket.
                let inactivityLimit = WirelessProtocolV2.heartbeatInterval * 4
                if let lastActivity = self.lastSocketActivityAt,
                   Date().timeIntervalSince(lastActivity) > inactivityLimit {
                    self.connectionFailed(generation: generation)
                    return
                }
                if let lease = self.activeLease {
                    try? self.sendSigned(type: .heartbeat, payload: [
                        "lease_id": lease.leaseID.uuidString.lowercased(),
                    ])
                } else {
                    task.sendPing { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self,
                                  self.socketGeneration == generation else { return }
                            if error == nil {
                                self.lastSocketActivityAt = Date()
                            } else {
                                self.connectionFailed(generation: generation)
                            }
                        }
                    }
                }
            }
        }
    }

    private func connectionFailed(generation: UUID) {
        guard generation == socketGeneration else { return }
        // Invalidate every other receive/send/ping callback belonging to this
        // socket before cancel() makes them complete. Only this path is then
        // allowed to create the single delayed reconnect work item.
        socketGeneration = UUID()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        tearDownSocket(notifyRelease: true)
        onConnectionState?(.disconnected)
        guard running, let endpoint = endpointURL, let deviceID = selectedDeviceID else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connectSocket(to: endpoint, deviceID: deviceID)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func tearDownSocket(notifyRelease: Bool) {
        // Callbacks from the socket being torn down must never act on the next
        // connection. connectSocket() assigns another generation after this.
        socketGeneration = UUID()
        pingTimer?.invalidate()
        pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        authenticatedRole = nil
        currentClientID = nil
        lastSocketActivityAt = nil
        let hadActiveLease = activeLease != nil
        activeLease = nil
        recentDeviceMessageIDs.removeAll(keepingCapacity: true)
        recentAudioMessageIDs.removeAll(keepingCapacity: true)
        latestDeviceTimestamp = 0
        let continuation = leaseContinuation
        leaseContinuation = nil
        continuation?.resume(throwing: VoiceProviderErrorCode.deviceNotFound)
        let pendingRevoke = revokeContinuation
        revokeContinuation = nil
        pendingRevoke?.resume(throwing: VoiceProviderErrorCode.deviceNotFound)
        if hadActiveLease { onAudioStateChanged?(.expired) }
        remotePTTPressed = false
        if notifyRelease { publishPTT(false) }
    }

    private func parseTXT(_ service: NetService) -> VoiceProviderDevice? {
        guard let data = service.txtRecordData() else { return nil }
        let values = NetService.dictionary(fromTXTRecord: data)
        func text(_ key: String) -> String? {
            values[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let deviceID = text("id"), deviceID.hasPrefix("MV-"),
              let model = text("model"),
              let firmware = text("fw"),
              let protocolText = text("pv"),
              let protocolVersion = UInt16(protocolText),
              protocolVersion == WirelessProtocolV2.version,
              let epochText = text("epoch"),
              let epoch = UInt32(epochText) else { return nil }
        return VoiceProviderDevice(
            deviceID: deviceID,
            nickname: text("name") ?? "inVoice StopWatch",
            model: model,
            firmwareVersion: firmware,
            protocolVersion: protocolVersion,
            bindingEpoch: epoch,
            isBound: WirelessDeviceCatalog.shared.binding(deviceID: deviceID) != nil,
            isOnline: true
        )
    }

    private func autoConnectIfEligible(deviceID: String) {
        guard socket == nil,
              WirelessDeviceCatalog.shared.binding(deviceID: deviceID) != nil else { return }
        let preferred = UserDefaults.standard.string(forKey: "wireless.defaultDeviceID")
        guard preferred == deviceID ||
                (preferred == nil && WirelessDeviceCatalog.shared.bindings.count == 1) else {
            return
        }
        selectedDeviceID = deviceID
        guard let endpoint = endpoints[deviceID] else { return }
        connectSocket(to: endpoint, deviceID: deviceID)
    }
}

extension WirelessVoiceProvider: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            let key = self.serviceKey(service)
            self.services[key] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = self.serviceKey(service)
            self.services.removeValue(forKey: key)
            if let deviceID = self.serviceDeviceIDs.removeValue(forKey: key) {
                self.endpoints.removeValue(forKey: deviceID)
                self.directory.markOffline(deviceID: deviceID)
                WirelessDeviceCatalog.shared.update(discovered: self.directory.devices)
                self.onDevicesChanged?(self.directory.devices)
                if self.selectedDeviceID == deviceID {
                    self.endpointURL = nil
                    self.tearDownSocket(notifyRelease: true)
                    self.onConnectionState?(.searching)
                }
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let hostName = sender.hostName
        let port = sender.port
        Task { @MainActor [weak self] in
            guard let self, self.running, let hostName, port > 0,
                  let device = self.parseTXT(sender) else { return }
            var components = URLComponents()
            components.scheme = "ws"
            components.host = hostName
            components.port = port
            components.path = "/v2/session"
            guard let url = components.url else { return }
            let key = self.serviceKey(sender)
            self.serviceDeviceIDs[key] = device.deviceID
            self.endpoints[device.deviceID] = url
            self.directory.upsert(device)
            WirelessDeviceCatalog.shared.update(discovered: self.directory.devices)
            self.onDevicesChanged?(self.directory.devices)
            self.autoConnectIfEligible(deviceID: device.deviceID)
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            NSLog("VoiceOps: wireless provider resolve failed: %@", errorDict)
            self.onConnectionState?(.searching)
        }
    }
}

/// Adapter for the unchanged USB implementation. AudioCaptureService and
/// FnKeyMonitor still perform the real work so existing USB timing, fallback
/// and permissions remain on their prior path.
@MainActor
final class USBProvider: VoiceProvider {
    let kind = VoiceInputProvider.usbAudio

    func discover() async throws -> [VoiceProviderDevice] { [] }
    func connect(deviceID: String?) async throws {}
    func disconnect() async {}
    func startAudio() async throws -> VoiceAudioLease? { nil }
    func stopAudio() async {}
    func sendControl(_ control: VoiceProviderControl) async throws {}
    func updateFirmware(_ image: Data) async throws {
        throw VoiceProviderErrorCode.otaNotAllowed
    }

    func getStatus() async throws -> VoiceProviderDeviceStatus {
        VoiceProviderDeviceStatus(
            device: VoiceProviderDevice(
                deviceID: "usb-audio",
                nickname: "Existing USB Audio",
                model: "ESP32-S3 USB",
                firmwareVersion: "legacy",
                protocolVersion: 1,
                bindingEpoch: 0,
                isBound: true,
                isOnline: true
            ),
            batteryPercent: nil,
            role: .controller,
            activeLease: nil,
            activeLeaseAppID: nil
        )
    }
}
