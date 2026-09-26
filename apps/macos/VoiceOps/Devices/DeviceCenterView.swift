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
                    title: "设备",
                    subtitle: "连接输入设备，按住就能说话。"
                )
                Spacer()
                Button {
                    isAddingDevice = true
                } label: {
                    Label("添加设备", systemImage: "plus")
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
            Text("我的设备")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if manager.snapshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wave.3.right.circle")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("还没有无线设备")
                        .font(.headline)
                    Text("内建和 USB 麦克风可直接使用。也可以连接 StopWatch。")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("添加 StopWatch") { isAddingDevice = true }
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
                Text("选择一个设备")
                    .font(.headline)
                Text("连接状态和设备信息会显示在这里。")
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
                        Text("默认")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("\(snapshot.shortID) · \(isConnected ? "已连接" : stageLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var stageLabel: String {
        switch snapshot.stage {
        case .ready: return "就绪"
        case .audioLeased: return "正在收音"
        case .busy: return "占用中"
        case .authenticating: return "正在验证"
        case .reconnecting: return "正在重连"
        case .offline: return "离线"
        default: return "已发现"
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
                    title: "连接状态",
                    subtitle: "查看设备是否准备好接收输入。"
                ) {
                    DeviceValueRow(label: "配对", value: bindingLabel)
                    DeviceValueRow(label: "发现方式", value: reachabilityLabel)
                    DeviceValueRow(label: "安全连接", value: sessionLabel)
                    DeviceValueRow(label: "音频", value: audioLabel)
                }

                DisclosureGroup("设备详情") {
                SectionCard(title: "设备信息", subtitle: "设备身份始终跟随硬件。") {
                    DeviceValueRow(label: "固件版本", value: snapshot.firmwareVersion)
                    DeviceValueRow(label: "协议版本", value: "v\(snapshot.protocolVersion)")
                    DeviceValueRow(label: "配对版本", value: String(snapshot.bindingEpoch))
                    if let battery = snapshot.batteryPercent {
                        DeviceValueRow(label: "电量", value: "\(battery)%")
                    }
                }

                }

                if let error = snapshot.lastError {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundColor(.orange)
                }

                HStack {
                    Button(manager.defaultDeviceID == snapshot.deviceID ? "默认设备" : "设为默认") {
                        manager.setDefault(deviceID: snapshot.deviceID)
                    }
                    .disabled(manager.defaultDeviceID == snapshot.deviceID)

                    if manager.connectedDeviceID == snapshot.deviceID {
                        Button("断开连接") {
                            Task { await manager.disconnect() }
                        }
                    } else {
                        Button("连接") {
                            Task { await manager.connect(deviceID: snapshot.deviceID) }
                        }
                        .disabled(
                            !snapshot.reachability.isBonjourVisible ||
                            !snapshot.binding.isBound
                        )
                    }

                    Button("更新固件…") { chooseFirmware() }
                        .disabled(
                            manager.connectedDeviceID != snapshot.deviceID ||
                            snapshot.binding.role != .owner
                        )
                }
                .buttonStyle(.bordered)

                Divider()

                Button("移除此 Mac…", role: .destructive) {
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
        .alert("从 \(snapshot.nickname) 移除此 Mac？", isPresented: $confirmUnbind) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await manager.unbind(deviceID: snapshot.deviceID) }
            }
        } message: {
            Text("只会移除此 Mac 的配对凭证，其他已授权设备不受影响。")
        }
    }

    private var bindingLabel: String {
        switch snapshot.binding {
        case .unbound: return "未配对"
        case .credentialInvalid: return "配对已失效，请重新配对"
        case .bound(let role): return role.rawValue.capitalized
        }
    }

    private var reachabilityLabel: String {
        switch snapshot.reachability {
        case .offline: return "离线"
        case .ble: return "通过蓝牙发现"
        case .bonjour: return "通过 Wi-Fi 发现"
        case .bleAndBonjour: return "通过蓝牙与 Wi-Fi 发现"
        }
    }

    private var sessionLabel: String {
        switch snapshot.session {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接"
        case .authenticating: return "正在验证身份"
        case .authenticated: return "已验证"
        case .reconnecting: return "正在重连"
        }
    }

    private var audioLabel: String {
        switch snapshot.audio {
        case .idle: return "空闲"
        case .leased: return "inVoice 正在使用"
        case .expired: return "使用已结束"
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
                    operationMessage = "所选固件文件为空。"
                    return
                }
                operationMessage = "正在上传固件…"
                await manager.updateFirmware(image, deviceID: snapshot.deviceID)
                operationMessage = "已发送更新，设备将验证固件并重启。"
            } catch {
                operationMessage = "无法读取固件文件。"
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
        case .ready: return "就绪"
        case .audioLeased: return "正在收音"
        case .busy: return "占用中"
        case .authenticating: return "正在验证"
        case .reconnecting: return "正在重连"
        case .offline: return "离线"
        default: return "已发现"
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
                    Text("添加 StopWatch")
                        .font(.title2.weight(.semibold))
                    Text(stepTitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                BLELinkBadge(state: provisioning.bleLinkState)
                Button("取消") { isPresented = false }
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
                        title: "正在连接蓝牙",
                        detail: provisioning.statusText
                    )
                case .confirmingIdentity:
                    identityStep
                case .awaitingPhysicalConfirmation:
                    pairingStep
                case .securePairing:
                    progressStep(
                        symbol: "lock.shield",
                        title: "正在完成配对",
                        detail: provisioning.statusText
                    )
                case .provisioningWiFi:
                    progressStep(
                        symbol: "wifi",
                        title: "正在配置 Wi-Fi",
                        detail: "网络信息只会发送给选中的设备，不会写入日志。"
                    )
                case .awaitingBonjour:
                    progressStep(
                        symbol: "network",
                        title: "正在查找 Wi-Fi 设备",
                        detail: "正在确认网络中的设备身份。"
                    )
                case .authenticating:
                    progressStep(
                        symbol: "checkmark.shield",
                        title: "正在验证连接",
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
            Label("附近的设备", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text("选择要连接的设备，下一步会核对设备编号。")
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
                Text("确认 StopWatch 屏幕上的编号为 \(identity.deviceID.split(separator: "-").last ?? "")，再继续。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 420)
                HStack {
                    Button("选择其他设备") { provisioning.cancelSelection() }
                    Button("编号一致") {
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
                Label("在设备上确认", systemImage: "hand.tap")
                    .font(.headline)
                Spacer()
                Text(countdownLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(secondsRemaining > 15 ? .secondary : .orange)
            }
            Text("长按 StopWatch 上的按钮，输入屏幕显示的六位配对码。")
                .font(.callout)
                .foregroundColor(.secondary)

            TextField("六位配对码", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())

            if secondsRemaining == 0 {
                HStack {
                    Label("配对已超时。", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("重新配对") {
                        pairingDeadline = Date().addingTimeInterval(WirelessProtocolV2.pairingWindow)
                        pairingCode = ""
                    }
                }
            }

            Toggle("配置设备的 Wi-Fi", isOn: $configureWiFi)

            if configureWiFi {
                TextField("Wi-Fi 名称", text: $lastSSID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Wi-Fi 密码", text: $wifiPassword)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("仅当设备已连接到同一个局域网时，才可跳过网络配置。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
            HStack {
                Button("返回") { provisioning.cancelSelection() }
                Spacer()
                Button("配对并继续") {
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
            Text("设备已就绪")
                .font(.title2.weight(.semibold))
            Text("\(deviceID) 已连接，现在可以开始使用。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 440)
            HStack {
                Button("完成") {
                    manager.select(deviceID: deviceID)
                    isPresented = false
                }
                Button("设为默认") {
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
            Text("暂时无法完成设置")
                .font(.title3.weight(.semibold))
            Text(error.message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 420)
            Text("\(error.code.rawValue) · Recovery: \(error.recovery.rawValue)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            HStack {
                Button("取消") { isPresented = false }
                Button(error.recovery == .rescan ? "重新搜索" : "重试") {
                    provisioning.retryAfterFailure()
                }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var stepTitle: String {
        switch provisioning.phase {
        case .idle, .scanning: return "1 / 5 · 选择设备"
        case .connecting, .confirmingIdentity: return "2 / 5 · 核对编号"
        case .awaitingPhysicalConfirmation, .securePairing: return "3 / 5 · 完成配对"
        case .provisioningWiFi: return "4 / 5 · 配置 Wi-Fi"
        case .awaitingBonjour, .authenticating: return "5 / 5 · 确认连接"
        case .complete: return "已完成"
        case .failed: return "恢复连接"
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
        return String(format: "剩余 %d:%02d", seconds / 60, seconds % 60)
    }

    private var isWaitingForNetwork: Bool {
        switch provisioning.phase {
        case .awaitingBonjour, .authenticating: return true
        default: return false
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        if rssi == 0 { return "已连接"
        }
        if rssi > -60 { return "强" }
        if rssi > -75 { return "良好" }
        return "弱"
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
        case .unavailable: return "蓝牙不可用"
        case .scanning: return "正在搜索"
        case .connecting: return "正在连接蓝牙"
        case .connected: return "蓝牙已连接"
        case .identityVerified: return "设备已确认"
        case .bindingSecured: return "配对已完成"
        case .wifiHandoff: return "已连接 Wi-Fi"
        case .failed: return "请检查蓝牙"
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
