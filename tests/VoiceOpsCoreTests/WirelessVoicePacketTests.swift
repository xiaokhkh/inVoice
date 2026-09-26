import Foundation
import XCTest
@testable import VoiceOpsCore

final class WirelessVoicePacketTests: XCTestCase {
    func testDecodesFirmwarePacket() throws {
        var data = Data([0x49, 0x56, 0x41, 0x31])
        data.append(contentsOf: [0x78, 0x56, 0x34, 0x12])
        data.append(contentsOf: [0x80, 0x3e, 0x00, 0x00])
        data.append(contentsOf: [0x03, 0x00, 0x2a, 0x01])
        data.append(contentsOf: [0x01, 0x00, 0xfe, 0xff, 0x34, 0x12])

        let packet = try WirelessVoiceAudioPacket(data: data)

        XCTAssertEqual(packet.sequence, 0x1234_5678)
        XCTAssertEqual(packet.sampleRate, 16_000)
        XCTAssertEqual(packet.sampleCount, 3)
        XCTAssertEqual(packet.level, 42)
        XCTAssertEqual(packet.flags, 1)
        XCTAssertEqual(packet.pcm16LE, Data([0x01, 0x00, 0xfe, 0xff, 0x34, 0x12]))
    }

    func testRejectsMismatchedPayloadLength() {
        var data = Data([0x49, 0x56, 0x41, 0x31])
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x80, 0x3e, 0x00, 0x00])
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00])

        XCTAssertThrowsError(try WirelessVoiceAudioPacket(data: data)) { error in
            XCTAssertEqual(
                error as? WirelessVoicePacketError,
                .invalidPayloadSize(expected: 20, actual: 18)
            )
        }
    }

    func testRejectsUnknownMagic() {
        let data = Data(repeating: 0, count: WirelessVoiceAudioPacket.headerSize)
        XCTAssertThrowsError(try WirelessVoiceAudioPacket(data: data)) { error in
            XCTAssertEqual(error as? WirelessVoicePacketError, .invalidMagic)
        }
    }

    func testDecodesProtocolV2PacketWithBoundIdentity() throws {
        var data = Data(repeating: 0, count: WirelessVoiceAudioPacket.v2HeaderSize)
        data.replaceSubrange(0..<4, with: Data("IVA2".utf8))
        putUInt16(2, in: &data, offset: 4)
        putUInt16(UInt16(WirelessVoiceAudioPacket.v2HeaderSize), in: &data, offset: 6)
        putUInt32(42, in: &data, offset: 8)
        putUInt32(16_000, in: &data, offset: 12)
        putUInt16(2, in: &data, offset: 16)
        data[18] = 71
        putUInt64(9_876, in: &data, offset: 20)
        putString("MV-A7K3P9Q2", in: &data, offset: 28, count: 20)
        putString("client-123", in: &data, offset: 48, count: 40)
        putString("session-456", in: &data, offset: 88, count: 40)
        data.replaceSubrange(128..<144, with: Data(0..<16))
        data.append(contentsOf: [0x34, 0x12, 0xfe, 0xff])

        let packet = try WirelessVoiceAudioPacket(data: data)

        XCTAssertEqual(packet.protocolVersion, 2)
        XCTAssertEqual(packet.sequence, 42)
        XCTAssertEqual(packet.timestampMilliseconds, 9_876)
        XCTAssertEqual(packet.deviceID, "MV-A7K3P9Q2")
        XCTAssertEqual(packet.clientID, "client-123")
        XCTAssertEqual(packet.sessionID, "session-456")
        XCTAssertEqual(packet.messageID, Data(0..<16))
        XCTAssertEqual(packet.pcm16LE, Data([0x34, 0x12, 0xfe, 0xff]))
    }

    private func putUInt16(_ value: UInt16, in data: inout Data, offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func putUInt32(_ value: UInt32, in data: inout Data, offset: Int) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }

    private func putUInt64(_ value: UInt64, in data: inout Data, offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }

    private func putString(_ value: String, in data: inout Data, offset: Int, count: Int) {
        let bytes = Data(value.utf8.prefix(count - 1))
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
