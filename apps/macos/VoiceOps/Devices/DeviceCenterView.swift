import AppKit
import Combine
import SwiftUI

struct DeviceCenterView: View {
    @StateObject private var manager = DeviceManager.shared
    @State private var isAddingDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PreferencesHeader(
                    title: "Devices",
                    subtitle: "Pair, select, and manage every inVoice input device in one place."
                )
                Spacer()
                Button {
                    isAddingDevice = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            HSplitView {
                deviceList
                    .frame(minWidth: 245, idealWidth: 265)
                detail
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .onAppear { manager.start() }
        .sheet(isPresented: $isAddingDevice) {
            AddDeviceFlow(isPresented: $isAddingDevice)
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MY DEVICES")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if manager.snapshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wave.3.right.circle")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("No wireless devices")
                        .font(.headline)
                    Text("USB input remains available. Add a StopWatch when you are ready.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("Add StopWatch") { isAddingDevice = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: Binding(
                    get: { manager.selectedDeviceID },
                    set: { manager.select(deviceID: $0) }
                )) {
                    ForEach(manager.snapshots) { snapshot in
                        DeviceListRow(
                            snapshot: snapshot,
                            isDefault: manager.defaultDeviceID == snapshot.deviceID,
                            isConnected: manager.connectedDeviceID == snapshot.deviceID
                        )
                        .tag(snapshot.deviceID)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let snapshot = manager.selectedDevice {
            DeviceDetailView(snapshot: snapshot)
                .id(snapshot.deviceID)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("Select a device")
                    .font(.headline)
                Text("Device identity, connection, binding, and audio state appear here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DeviceListRow: View {
    let snapshot: DeviceSnapshot
    let isDefault: Bool
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundColor(statusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(snapshot.nickname)
                        .lineLimit(1)
                    if isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("\(snapshot.shortID) · \(isConnected ? "Connected" : stageLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var stageLabel: String {
        switch snapshot.stage {
        case .ready: return "Ready"
        case .audioLeased: return "Audio active"
        case .busy: return "Busy"
        case .authenticating: return "Authenticating"
        case .reconnecting: return "Reconnecting"
        case .offline: return "Offline"
        default: return "Discovered"
        }
    }

    private var statusSymbol: String {
        switch snapshot.stage {
        case .ready, .audioLeased: return "circle.fill"
        case .busy: return "exclamationmark.circle.fill"
        case .reconnecting, .authenticating: return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch snapshot.stage {
        case .ready, .audioLeased: return .green
        case .busy: return .orange
        default: return .secondary
        }
    }
}

private struct DeviceDetailView: View {
    let snapshot: DeviceSnapshot
    @StateObject private var manager = DeviceManager.shared
    @State private var confirmUnbind = false
    @State private var operationMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.nickname)
                            .font(.title2.weight(.semibold))
                        Text("\(snapshot.deviceID) · \(snapshot.model)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    DeviceStateBadge(snapshot: snapshot)
                }

                SectionCard(
                    title: "Status",
                    subtitle: "Binding, discovery, session, and audio are tracked independently."
                ) {
                    DeviceValueRow(label: "Binding", value: bindingLabel)
                    DeviceValueRow(label: "Reachability", value: reachabilityLabel)
                    DeviceValueRow(label: "Secure session", value: sessionLabel)
                    DeviceValueRow(label: "Audio", value: audioLabel)
                }

                SectionCard(title: "Device information", subtitle: "Identity follows the physical hardware, not its IP address.") {
                    DeviceValueRow(label: "Firmware", value: snapshot.firmwareVersion)
                    DeviceValueRow(label: "Protocol", value: "v\(snapshot.protocolVersion)")
                    DeviceValueRow(label: "Binding epoch", value: String(snapshot.bindingEpoch))
                    if let battery = snapshot.batteryPercent {
                        DeviceValueRow(label: "Battery", value: "\(battery)%")
                    }
                }

                if let error = snapshot.lastError {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundColor(.orange)
                }

                HStack {
                    Button(manager.defaultDeviceID == snapshot.deviceID ? "Default Device" : "Set as Default") {
                        manager.setDefault(deviceID: snapshot.deviceID)
                    }
                    .disabled(manager.defaultDeviceID == snapshot.deviceID)

                    if manager.connectedDeviceID == snapshot.deviceID {
                        Button("Disconnect") {
                            Task { await manager.disconnect() }
                        }
                    } else {
                        Button("Connect") {
                            Task { await manager.connect(deviceID: snapshot.deviceID) }
                        }
                        .disabled(
                            !snapshot.reachability.isBonjourVisible ||
                            !snapshot.binding.isBound
                        )
                    }

                    Button("Update Firmware…") { chooseFirmware() }
                        .disabled(
                            manager.connectedDeviceID != snapshot.deviceID ||
                            snapshot.binding.role != .owner
                        )
                }
                .buttonStyle(.bordered)

                Divider()

                Button("Remove This Mac…", role: .destructive) {
                    confirmUnbind = true
                }
                .disabled(snapshot.binding.role != .owner)

                if !operationMessage.isEmpty {
                    Text(operationMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(18)
        }
        .alert("Remove this Mac from \(snapshot.nickname)?", isPresented: $confirmUnbind) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await manager.unbind(deviceID: snapshot.deviceID) }
            }
        } message: {
            Text("The device revokes only this client credential. Other authorized clients are not affected.")
        }
    }

    private var bindingLabel: String {
        switch snapshot.binding {
        case .unbound: return "Not paired"
        case .credentialInvalid: return "Credential invalid · pair again"
        case .bound(let role): return role.rawValue.capitalized
        }
    }

    private var reachabilityLabel: String {
        switch snapshot.reachability {
        case .offline: return "Offline"
        case .ble: return "Bluetooth visible"
        case .bonjour: return "Bonjour / Wi-Fi visible"
        case .bleAndBonjour: return "Bluetooth + Bonjour visible"
        }
    }

    private var sessionLabel: String {
        switch snapshot.session {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .authenticating: return "Mutual authentication"
        case .authenticated: return "Authenticated"
        case .reconnecting: return "Reconnecting"
        }
    }

    private var audioLabel: String {
        switch snapshot.audio {
        case .idle: return "Idle"
        case .leased: return "Leased to inVoice"
        case .expired: return "Lease expired"
        case .busy(let appID, _): return "Busy\(appID.map { " · \($0)" } ?? "")"
        }
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "Choose signed StopWatch firmware"
        panel.prompt = "Update"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let image = try Data(contentsOf: url)
                guard !image.isEmpty else {
                    operationMessage = "The selected firmware image is empty."
                    return
                }
                operationMessage = "Uploading signed firmware…"
                await manager.updateFirmware(image, deviceID: snapshot.deviceID)
                operationMessage = "Update request sent. The device will verify and restart."
            } catch {
                operationMessage = "Could not read the firmware image."
            }
        }
    }
}

private struct DeviceStateBadge: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch snapshot.stage {
        case .ready: return "READY"
        case .audioLeased: return "AUDIO ACTIVE"
        case .busy: return "BUSY"
        case .authenticating: return "AUTHENTICATING"
        case .reconnecting: return "RECONNECTING"
        case .offline: return "OFFLINE"
        default: return "DISCOVERED"
        }
    }

    private var color: Color {
        switch snapshot.stage {
        case .ready, .audioLeased: return .green
        case .busy: return .orange
        default: return .secondary
        }
    }
}

private struct DeviceValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct AddDeviceFlow: View {
    @Binding var isPresented: Bool
    @StateObject private var provisioning = WirelessProvisioningService()
    @StateObject private var manager = DeviceManager.shared
    @AppStorage("wireless.lastSSID") private var lastSSID = ""
    @State private var wifiPassword = ""
    @State private var pairingCode = ""
    @State private var configureWiFi = true
    @State private var pairingDeadline: Date?
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add StopWatch")
                        .font(.title2.weight(.semibold))
                    Text(stepTitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                BLELinkBadge(state: provisioning.bleLinkState)
                Button("Cancel") { isPresented = false }
                    .disabled(provisioning.isBusy && !isWaitingForNetwork)
            }
            .padding(20)

            Divider()

            Group {
                switch provisioning.phase {
                case .idle, .scanning:
                    discoveryStep
                case .connecting:
                    progressStep(
                        symbol: "antenna.radiowaves.left.and.right",
                        title: "Connecting over Bluetooth",
                        detail: provisioning.statusText
                    )
                case .confirmingIdentity:
                    identityStep
                case .awaitingPhysicalConfirmation:
                    pairingStep
                case .securePairing:
                    progressStep(
                        symbol: "lock.shield",
                        title: "Creating the secure binding",
                        detail: provisioning.statusText
                    )
                case .provisioningWiFi:
                    progressStep(
                        symbol: "wifi",
                        title: "Sending Wi-Fi configuration",
                        detail: "Credentials are sent only through the selected BLE session and are never logged."
                    )
                case .awaitingBonjour:
                    progressStep(
                        symbol: "network",
                        title: "Finding the same device on Wi-Fi",
                        detail: "Setup finishes only after Bonjour returns the same device ID and mutual authentication succeeds."
                    )
                case .authenticating:
                    progressStep(
                        symbol: "checkmark.shield",
                        title: "Authenticating both sides",
                        detail: provisioning.statusText
                    )
                case .complete(let deviceID):
                    completionStep(deviceID: deviceID)
                case .failed(let error):
                    errorStep(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(width: 620, height: 520)
        .onAppear { provisioning.startScanning() }
        .onDisappear { provisioning.stopScanning() }
        .onReceive(timer) { date in
            now = date
            synchronizeNetworkAuthentication()
        }
        .onReceive(manager.$snapshots) { _ in
            synchronizeNetworkAuthentication()
        }
    }

    private var discoveryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nearby devices", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text("Choose a device explicitly. Names are only labels; the next step verifies its permanent device ID.")
                .font(.callout)
                .foregroundColor(.secondary)

            if provisioning.nearbyDevices.isEmpty {
                Spacer()
                ProgressView("Scanning for inVoice StopWatch…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(provisioning.nearbyDevices) { device in
                    Button {
                        provisioning.selectDevice(id: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.nickname ?? device.displayName)
                                    .font(.headline)
                                Text(device.identityLabel)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(signalLabel(device.rssi))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var identityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "watchface.applewatch.case")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            if let identity = provisioning.selectedIdentity {
                Text(identity.nickname)
                    .font(.title2.weight(.semibold))
                Text(identity.deviceID)
                    .font(.title3.monospaced().weight(.medium))
                Text(identity.model)
                    .foregroundColor(.secondary)
                Text("Check that the short ID \(identity.deviceID.split(separator: "-").last ?? "") is shown on the StopWatch before continuing.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 420)
                HStack {
                    Button("Choose Another Device") { provisioning.cancelSelection() }
                    Button("ID Matches") {
                        manager.recordBLEIdentity(
                            deviceID: identity.deviceID,
                            nickname: identity.nickname,
                            model: identity.model,
                            bindingEpoch: identity.bindingEpoch
                        )
                        pairingDeadline = Date().addingTimeInterval(WirelessProtocolV2.pairingWindow)
                        provisioning.confirmPhysicalIdentity()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var pairingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Physical confirmation", systemImage: "hand.tap")
                    .font(.headline)
                Spacer()
                Text(countdownLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(secondsRemaining > 15 ? .secondary : .orange)
            }
            Text("Long-press the button on the selected StopWatch. Enter only the six-digit code shown on that device.")
                .font(.callout)
                .foregroundColor(.secondary)

            TextField("Six-digit pairing code", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())

            if secondsRemaining == 0 {
                HStack {
                    Label("The local pairing timer expired.", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Start a New 2-Minute Window") {
                        pairingDeadline = Date().addingTimeInterval(WirelessProtocolV2.pairingWindow)
                        pairingCode = ""
                    }
                }
            }

            Toggle("Configure or update this device's Wi-Fi", isOn: $configureWiFi)

            if configureWiFi {
                TextField("Wi-Fi name (SSID)", text: $lastSSID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Wi-Fi password", text: $wifiPassword)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("Use this only when the selected device is already on the same local network.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
            HStack {
                Button("Back") { provisioning.cancelSelection() }
                Spacer()
                Button("Pair and Continue") {
                    let accepted: Bool
                    if configureWiFi {
                        accepted = provisioning.configure(
                            ssid: lastSSID,
                            password: wifiPassword,
                            pairingCode: pairingCode
                        )
                    } else {
                        accepted = provisioning.pair(pairingCode: pairingCode)
                    }
                    if accepted {
                        wifiPassword = ""
                        pairingCode = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitPairing)
            }
        }
    }

    private func progressStep(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(width: 220)
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 430)
        }
    }

    private func completionStep(deviceID: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
            Text("Device Ready")
                .font(.title2.weight(.semibold))
            Text("\(deviceID) was found by Bonjour and completed mutual authentication. It is now available in Device Center.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 440)
            HStack {
                Button("Done") {
                    manager.select(deviceID: deviceID)
                    isPresented = false
                }
                Button("Use as Default") {
                    manager.setDefault(deviceID: deviceID)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorStep(_ error: DeviceActionError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundColor(.orange)
            Text("Setup could not continue")
                .font(.title3.weight(.semibold))
            Text(error.message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 420)
            Text("\(error.code.rawValue) · Recovery: \(error.recovery.rawValue)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            HStack {
                Button("Cancel") { isPresented = false }
                Button(error.recovery == .rescan ? "Scan Again" : "Try Again") {
                    provisioning.retryAfterFailure()
                }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var stepTitle: String {
        switch provisioning.phase {
        case .idle, .scanning: return "1 of 5 · Choose a nearby device"
        case .connecting, .confirmingIdentity: return "2 of 5 · Verify physical identity"
        case .awaitingPhysicalConfirmation, .securePairing: return "3 of 5 · Pair securely"
        case .provisioningWiFi: return "4 of 5 · Configure Wi-Fi"
        case .awaitingBonjour, .authenticating: return "5 of 5 · Verify the Wi-Fi connection"
        case .complete: return "Complete"
        case .failed: return "Recovery"
        }
    }

    private var canSubmitPairing: Bool {
        pairingCode.count == 6 &&
        pairingCode.allSatisfy(\.isNumber) &&
        secondsRemaining > 0 &&
        (!configureWiFi || !lastSSID.isEmpty) &&
        !provisioning.isBusy
    }

    private var secondsRemaining: Int {
        guard let pairingDeadline else { return Int(WirelessProtocolV2.pairingWindow) }
        return max(0, Int(pairingDeadline.timeIntervalSince(now).rounded(.up)))
    }

    private var countdownLabel: String {
        let seconds = secondsRemaining
        return String(format: "%d:%02d remaining", seconds / 60, seconds % 60)
    }

    private var isWaitingForNetwork: Bool {
        switch provisioning.phase {
        case .awaitingBonjour, .authenticating: return true
        default: return false
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        if rssi == 0 { return "Connected"
        }
        if rssi > -60 { return "Strong" }
        if rssi > -75 { return "Good" }
        return "Weak"
    }

    private func synchronizeNetworkAuthentication() {
        guard let deviceID = provisioning.pairedDeviceID,
              let snapshot = manager.snapshot(deviceID: deviceID) else { return }
        if let error = snapshot.lastError {
            provisioning.reportAuthenticationFailure(error)
            return
        }
        if snapshot.session == .authenticated {
            provisioning.markAuthenticated(deviceID: deviceID)
        } else if snapshot.reachability.isBonjourVisible,
                  snapshot.session == .authenticating || snapshot.session == .connecting {
            provisioning.markAuthenticating(deviceID: deviceID)
        }
    }
}

private struct BLELinkBadge: View {
    let state: WirelessBLELinkState

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .unavailable: return "Bluetooth unavailable"
        case .scanning: return "Scanning"
        case .connecting: return "BLE connecting"
        case .connected: return "BLE connected"
        case .identityVerified: return "Device verified"
        case .bindingSecured: return "Binding secured"
        case .wifiHandoff: return "Using Wi-Fi"
        case .failed: return "BLE needs attention"
        }
    }

    private var symbol: String {
        switch state {
        case .unavailable, .failed: return "exclamationmark.triangle"
        case .scanning, .connecting: return "antenna.radiowaves.left.and.right"
        case .connected, .identityVerified, .bindingSecured:
            return "checkmark.shield"
        case .wifiHandoff: return "wifi"
        }
    }

    private var color: Color {
        switch state {
        case .unavailable, .failed: return .orange
        case .bindingSecured: return .green
        default: return .accentColor
        }
    }
}
