import Foundation
import XCTest
@testable import VoiceOpsCore

final class DeviceSnapshotTests: XCTestCase {
    func testBLEAndBonjourAreIndependentReachabilitySignals() {
        let now = Date(timeIntervalSince1970: 100)
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")

        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bleVisibility(true, at: now)
        )
        XCTAssertEqual(snapshot.reachability, .ble)

        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourDevice(device(), at: now)
        )
        XCTAssertEqual(snapshot.reachability, .bleAndBonjour)

        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourLost(at: now)
        )
        XCTAssertEqual(snapshot.reachability, .ble)
    }

    func testBindingRoleDoesNotImplyAnAuthenticatedSession() {
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .binding(binding(epoch: 4, role: .owner))
        )

        XCTAssertEqual(snapshot.binding, .bound(.owner))
        XCTAssertEqual(snapshot.session, .disconnected)
        XCTAssertEqual(snapshot.stage, .offline)
    }

    func testChangedBindingEpochInvalidatesStoredCredential() {
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourDevice(device(epoch: 5), at: Date())
        )
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .binding(binding(epoch: 4, role: .owner))
        )

        XCTAssertEqual(snapshot.binding, .credentialInvalid)
        XCTAssertEqual(snapshot.lastError?.recovery, .rebind)
    }

    func testReadyAndAudioLeaseStagesRequireSeparateEvents() {
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourDevice(device(), at: Date())
        )
        snapshot = DeviceStateReducer.reduce(snapshot, event: .session(.authenticated))
        XCTAssertEqual(snapshot.stage, .ready)

        snapshot = DeviceStateReducer.reduce(snapshot, event: .audio(.leased))
        XCTAssertEqual(snapshot.stage, .audioLeased)

        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .audio(.busy(appID: "debug-tool", clientID: "client-b"))
        )
        XCTAssertEqual(snapshot.stage, .busy)
    }

    func testNetworkLossOverridesAStaleAudioLease() {
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourDevice(device(), at: Date())
        )
        snapshot = DeviceStateReducer.reduce(snapshot, event: .session(.authenticated))
        snapshot = DeviceStateReducer.reduce(snapshot, event: .audio(.leased))

        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourLost(at: Date())
        )

        XCTAssertEqual(snapshot.session, .reconnecting)
        XCTAssertEqual(snapshot.audio, .expired)
        XCTAssertEqual(snapshot.stage, .reconnecting)
    }

    func testStaleStatusCannotReviveAnEpochInvalidCredential() {
        var snapshot = DeviceStateReducer.placeholder(deviceID: "MV-A7K3P9Q2")
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .bonjourDevice(device(epoch: 5), at: Date())
        )
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .binding(binding(epoch: 4, role: .owner))
        )
        snapshot = DeviceStateReducer.reduce(
            snapshot,
            event: .status(VoiceProviderDeviceStatus(
                device: device(epoch: 4),
                batteryPercent: 90,
                role: .owner,
                activeLease: nil,
                activeLeaseAppID: nil
            ))
        )

        XCTAssertEqual(snapshot.binding, .credentialInvalid)
    }

    func testSameNicknameNeverCollapsesPermanentIDs() {
        let first = DeviceStateReducer.placeholder(
            deviceID: "MV-A7K3P9Q2",
            nickname: "Studio"
        )
        let second = DeviceStateReducer.placeholder(
            deviceID: "MV-Z9X8C7V6",
            nickname: "Studio"
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set([first.id, second.id]).count, 2)
    }

    private func device(epoch: UInt32 = 4) -> VoiceProviderDevice {
        VoiceProviderDevice(
            deviceID: "MV-A7K3P9Q2",
            nickname: "Studio",
            model: "M5Stack StopWatch",
            firmwareVersion: "0.2.1",
            protocolVersion: WirelessProtocolV2.version,
            bindingEpoch: epoch,
            isBound: true,
            isOnline: true
        )
    }

    private func binding(epoch: UInt32, role: VoiceProviderRole) -> WirelessBindingSummary {
        WirelessBindingSummary(
            deviceID: "MV-A7K3P9Q2",
            nickname: "Studio",
            model: "M5Stack StopWatch",
            role: role,
            bindingEpoch: epoch
        )
    }
}
