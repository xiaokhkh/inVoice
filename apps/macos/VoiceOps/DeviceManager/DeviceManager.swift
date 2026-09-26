import Combine
import Foundation

/// The single in-process source of device truth. Its public surface is kept
/// transport-neutral so it can move behind a localhost/UDS Device Manager
/// without changing the views or dictation pipeline.
@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var snapshots: [DeviceSnapshot] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var connectedDeviceID: String?
    @Published private(set) var lastActionError: DeviceActionError?

    var defaultDeviceID: String? {
        catalog.defaultDeviceID
    }

    var selectedDevice: DeviceSnapshot? {
        snapshot(deviceID: selectedDeviceID)
    }

    var connectedDevice: DeviceSnapshot? {
        snapshot(deviceID: connectedDeviceID)
    }

    var inputSourceSummary: String {
        guard let connectedDevice else { return "Input device: USB / Mac microphone" }
        return "Input device: \(connectedDevice.nickname) · \(connectedDevice.shortID)"
    }

    var audioSummary: String {
        guard let connectedDevice else { return "Audio: USB path ready" }
        switch connectedDevice.audio {
        case .idle: return "Audio: wireless ready"
        case .leased: return "Audio: in use by inVoice"
        case .busy(let appID, _):
            return "Audio: busy\(appID.map { " · \($0)" } ?? "")"
        case .expired: return "Audio: lease expired"
        }
    }

    private let catalog = WirelessDeviceCatalog.shared
    private let provider = WirelessVoiceProvider.shared
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var stateByID: [String: DeviceSnapshot] = [:]

    private init() {
        selectedDeviceID = catalog.defaultDeviceID
        catalog.$devices
            .combineLatest(catalog.$statuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.rebuildFromCatalog()
            }
            .store(in: &cancellables)
        rebuildFromCatalog()
    }

    func start() {
        guard !started else { return }
        started = true
        provider.start()
        rebuildFromCatalog()
    }

    func snapshot(deviceID: String?) -> DeviceSnapshot? {
        guard let deviceID else { return nil }
        return stateByID[deviceID]
    }

    func select(deviceID: String?) {
        selectedDeviceID = deviceID
    }

    func setDefault(deviceID: String) {
        selectedDeviceID = deviceID
        catalog.defaultDeviceID = deviceID
        objectWillChange.send()
    }

    func connect(deviceID: String) async {
        selectedDeviceID = deviceID
        apply(.session(.connecting), to: deviceID)
        do {
            try await provider.connect(deviceID: deviceID)
        } catch {
            fail(
                deviceID: deviceID,
                stage: .authenticating,
                error: error,
                recovery: .retry,
                message: "The selected device is not reachable on the local network yet."
            )
        }
    }

    func disconnect() async {
        let prior = connectedDeviceID ?? selectedDeviceID
        await provider.disconnect()
        connectedDeviceID = nil
        if let prior { apply(.session(.disconnected), to: prior) }
    }

    func unbind(deviceID: String) async {
        do {
            try await provider.unbind(deviceID: deviceID)
            stateByID.removeValue(forKey: deviceID)
            if selectedDeviceID == deviceID { selectedDeviceID = nil }
            if connectedDeviceID == deviceID { connectedDeviceID = nil }
            publish()
        } catch {
            fail(
                deviceID: deviceID,
                stage: .ready,
                error: error,
                recovery: .retry,
                message: "Connect as the device owner before removing this Mac."
            )
        }
    }

    func updateFirmware(_ image: Data, deviceID: String) async {
        guard connectedDeviceID == deviceID else {
            fail(
                deviceID: deviceID,
                stage: .ready,
                error: VoiceProviderErrorCode.deviceNotFound,
                recovery: .retry,
                message: "Connect to this device before starting an update."
            )
            return
        }
        do {
            try await provider.updateFirmware(image)
        } catch {
            fail(
                deviceID: deviceID,
                stage: .ready,
                error: error,
                recovery: .updateFirmware,
                message: "The signed firmware update was rejected or interrupted."
            )
        }
    }

    func recordBLEIdentity(
        deviceID: String,
        nickname: String,
        model: String,
        bindingEpoch: UInt32
    ) {
        var snapshot = stateByID[deviceID] ?? DeviceStateReducer.placeholder(
            deviceID: deviceID,
            nickname: nickname,
            model: model
        )
        snapshot.nickname = nickname
        snapshot.model = model
        snapshot.bindingEpoch = bindingEpoch
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bleVisibility(true, at: Date())
        )
        stateByID[deviceID] = snapshot
        selectedDeviceID = deviceID
        applyStoredBinding(to: deviceID)
        publish()
    }

    func clearBLEVisibility(deviceID: String) {
        apply(.bleVisibility(false, at: Date()), to: deviceID)
    }

    func pairingDidPersist(deviceID: String) {
        selectedDeviceID = deviceID
        catalog.refresh()
        if catalog.defaultDeviceID == nil {
            catalog.defaultDeviceID = deviceID
        }
        applyStoredBinding(to: deviceID)
        publish()
    }

    func handleConnectionState(_ state: WirelessVoiceProvider.ConnectionState) {
        switch state {
        case .searching:
            if let deviceID = connectedDeviceID ?? selectedDeviceID {
                apply(.session(.reconnecting), to: deviceID)
            }
        case .connecting(let deviceID):
            selectedDeviceID = deviceID
            apply(.session(.connecting), to: deviceID)
        case .authenticating(let deviceID):
            selectedDeviceID = deviceID
            apply(.session(.authenticating), to: deviceID)
        case .connected(let deviceID):
            selectedDeviceID = deviceID
            connectedDeviceID = deviceID
            apply(.session(.authenticated), to: deviceID)
        case .busy(let deviceID, let clientID):
            apply(.audio(.busy(appID: nil, clientID: clientID)), to: deviceID)
        case .disconnected:
            if let deviceID = connectedDeviceID ?? selectedDeviceID {
                let session: DeviceSessionState = stateByID[deviceID]?.reachability.isBonjourVisible == true
                    ? .reconnecting
                    : .disconnected
                apply(.session(session), to: deviceID)
            }
            connectedDeviceID = nil
        }
    }

    func handleAudioState(_ state: DeviceAudioState) {
        guard let deviceID = connectedDeviceID ?? selectedDeviceID else { return }
        apply(.audio(state), to: deviceID)
    }

    private func rebuildFromCatalog() {
        let devices = catalog.devices
        let deviceIDs = Set(devices.map(\.deviceID))
        let now = Date()

        for deviceID in stateByID.keys.filter({ !deviceIDs.contains($0) }) {
            guard let snapshot = stateByID[deviceID] else { continue }
            stateByID[deviceID] = DeviceStateReducer.reduce(
                snapshot,
                event: .bonjourLost(at: now)
            )
        }

        for device in devices {
            var snapshot = stateByID[device.deviceID] ?? DeviceStateReducer.placeholder(
                deviceID: device.deviceID,
                nickname: device.nickname,
                model: device.model
            )
            if device.isOnline {
                snapshot = DeviceStateReducer.reduce(
                    snapshot,
                    event: .bonjourDevice(device, at: now)
                )
            } else {
                snapshot.nickname = device.nickname
                snapshot.model = device.model
                snapshot.firmwareVersion = device.firmwareVersion
                snapshot.bindingEpoch = device.bindingEpoch
                snapshot = DeviceStateReducer.reduce(snapshot, event: .bonjourLost(at: now))
            }
            stateByID[device.deviceID] = snapshot
            applyStoredBinding(to: device.deviceID)
            if let status = catalog.statuses[device.deviceID] {
                apply(.status(status), to: device.deviceID)
                if let lease = status.activeLease {
                    let ownClientID = catalog.clientID
                    apply(
                        .audio(lease.clientID == ownClientID
                            ? .leased
                            : .busy(
                                appID: status.activeLeaseAppID,
                                clientID: lease.clientID.uuidString.lowercased()
                            )),
                        to: device.deviceID
                    )
                }
            }
        }
        if selectedDeviceID == nil { selectedDeviceID = catalog.defaultDeviceID }
        publish()
    }

    private func applyStoredBinding(to deviceID: String) {
        guard var snapshot = stateByID[deviceID] else { return }
        let binding = catalog.binding(deviceID: deviceID)
        let summary = binding.map {
            WirelessBindingSummary(
                deviceID: $0.deviceID,
                nickname: $0.nickname,
                model: $0.model,
                role: $0.role,
                bindingEpoch: $0.bindingEpoch
            )
        }
        snapshot = DeviceStateReducer.reduce(snapshot, event: .binding(summary))
        stateByID[deviceID] = snapshot
    }

    private func apply(_ event: DeviceStateEvent, to deviceID: String) {
        let current = stateByID[deviceID] ?? DeviceStateReducer.placeholder(deviceID: deviceID)
        stateByID[deviceID] = DeviceStateReducer.reduce(current, event: event)
        publish()
    }

    private func fail(
        deviceID: String,
        stage: DeviceJourneyStage,
        error: Error,
        recovery: DeviceRecoveryAction,
        message: String
    ) {
        let code = (error as? VoiceProviderErrorCode) ?? .invalidMessage
        let actionError = DeviceActionError(
            stage: stage,
            code: code,
            message: message,
            recovery: recovery
        )
        lastActionError = actionError
        apply(.failed(actionError), to: deviceID)
    }

    private func publish() {
        snapshots = stateByID.values.sorted {
            if $0.nickname == $1.nickname { return $0.deviceID < $1.deviceID }
            return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
        }
    }
}
