import Foundation
import XCTest
@testable import VoiceOpsCore

final class WirelessProtocolTests: XCTestCase {
    func testProtocolRoundTripCarriesRequiredMetadata() throws {
        let header = WirelessProtocolHeader(
            deviceID: "MV-A7K3P9Q2",
            clientID: "client-1",
            sessionID: "session-1",
            messageID: "message-1",
            timestamp: 1_724_100_000_000,
            messageType: .acquireAudioLease
        )
        let original = WirelessProtocolMessage(
            header: header,
            payload: ["force": "false"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WirelessProtocolMessage.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"protocol_version\":2"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"device_id\""))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"message_type\""))
    }

    func testCanonicalSignatureInputDoesNotDependOnDictionaryOrder() {
        let header = WirelessProtocolHeader(
            deviceID: "MV-A7K3P9Q2",
            clientID: "client-1",
            sessionID: "session-1",
            messageID: "message-1",
            timestamp: 123,
            messageType: .authenticate
        )
        let lhs = WirelessProtocolMessage(
            header: header,
            payload: ["nonce": "abc", "epoch": "4"]
        )
        let rhs = WirelessProtocolMessage(
            header: header,
            payload: ["epoch": "4", "nonce": "abc"]
        )

        XCTAssertEqual(lhs.signingBytes(), rhs.signingBytes())
    }

    func testPairingRequiresWindowExpiresAndLocksAfterFiveFailures() {
        let now = Date(timeIntervalSince1970: 100)
        var gate = WirelessPairingGate(bindingEpoch: 2)

        assertFailure(gate.confirm(code: "123456", now: now), .pairingDisabled)
        gate.open(code: "654321", now: now, forceRebind: true)
        XCTAssertEqual(gate.bindingEpoch, 3)

        for _ in 0..<5 {
            assertFailure(gate.confirm(code: "000000", now: now), .invalidPairCode)
        }
        assertFailure(gate.confirm(code: "654321", now: now), .pairingDisabled)

        gate.open(code: "654321", now: now)
        assertFailure(
            gate.confirm(code: "654321", now: now.addingTimeInterval(121)),
            .pairCodeExpired
        )
    }

    func testFirstLeaseWinsThenExpires() throws {
        let now = Date(timeIntervalSince1970: 100)
        let firstClient = UUID()
        let secondClient = UUID()
        var leases = WirelessAudioLeaseCoordinator()

        let first = leases.acquire(
            deviceID: "MV-A7K3P9Q2",
            clientID: firstClient,
            sessionID: UUID(),
            role: .controller,
            now: now
        )
        guard case .acquired(let firstLease) = first else {
            return XCTFail("first controller should acquire the lease")
        }

        let second = leases.acquire(
            deviceID: "MV-A7K3P9Q2",
            clientID: secondClient,
            sessionID: UUID(),
            role: .controller,
            now: now
        )
        XCTAssertEqual(second, .busy(firstLease))

        let afterTimeout = leases.acquire(
            deviceID: "MV-A7K3P9Q2",
            clientID: secondClient,
            sessionID: UUID(),
            role: .controller,
            now: now.addingTimeInterval(WirelessProtocolV2.leaseDuration + 0.01)
        )
        guard case .acquired(let secondLease) = afterTimeout else {
            return XCTFail("expired lease should be released")
        }
        XCTAssertEqual(secondLease.clientID, secondClient)
    }

    func testOnlyOwnerCanForceReleaseAnotherClient() {
        let now = Date(timeIntervalSince1970: 100)
        let firstClient = UUID()
        let owner = UUID()
        var leases = WirelessAudioLeaseCoordinator()
        guard case .acquired(let lease) = leases.acquire(
            deviceID: "MV-A7K3P9Q2",
            clientID: firstClient,
            sessionID: UUID(),
            role: .controller,
            now: now
        ) else {
            return XCTFail("expected lease")
        }

        XCTAssertFalse(leases.release(
            leaseID: lease.leaseID,
            clientID: owner,
            role: .controller,
            force: true
        ))
        XCTAssertTrue(leases.release(
            leaseID: lease.leaseID,
            clientID: owner,
            role: .owner,
            force: true
        ))
    }

    func testSameNicknameDevicesRemainDistinct() {
        var directory = WirelessDeviceDirectory()
        directory.upsert(device(id: "MV-A7K3P9Q2", nickname: "Studio"))
        directory.upsert(device(id: "MV-Z9X8C7V6", nickname: "Studio"))

        XCTAssertEqual(directory.devices.count, 2)
        XCTAssertNotNil(directory.device(id: "MV-A7K3P9Q2"))
        XCTAssertNotNil(directory.device(id: "MV-Z9X8C7V6"))
    }

    func testRolePermissionsAreDeviceEnforceable() {
        XCTAssertTrue(VoiceProviderRole.owner.allows(.manageClients))
        XCTAssertTrue(VoiceProviderRole.controller.allows(.audio))
        XCTAssertFalse(VoiceProviderRole.controller.allows(.updateFirmware))
        XCTAssertTrue(VoiceProviderRole.viewer.allows(.readStatus))
        XCTAssertFalse(VoiceProviderRole.viewer.allows(.control))
    }

    private func device(id: String, nickname: String) -> VoiceProviderDevice {
        VoiceProviderDevice(
            deviceID: id,
            nickname: nickname,
            model: "M5Stack StopWatch",
            firmwareVersion: "0.2.0",
            protocolVersion: WirelessProtocolV2.version,
            bindingEpoch: 1,
            isBound: true,
            isOnline: true
        )
    }

    private func assertFailure(
        _ result: Result<Void, VoiceProviderErrorCode>,
        _ expected: VoiceProviderErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail("expected failure \(expected)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
