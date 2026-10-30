import NIOCore
import Testing
@testable import ProvisionerPXE

@Suite struct TFTPPacketTests {
    @Test(arguments: [
        TFTPPacket.readRequest(filename: "grub/grub.cfg", mode: "octet", options: [TFTPOption(name: "blksize", value: "1468")]),
        .writeRequest(filename: "x", mode: "octet"),
        .data(block: 7, payload: ByteBuffer(bytes: [1, 2, 3])),
        .ack(block: 65535),
        .error(code: 1, message: "File not found"),
        .optionAck([TFTPOption(name: "tsize", value: "1234")]),
    ])
    func roundTripsEach(packet: TFTPPacket) {
        #expect(TFTPPacket(buffer: packet.encoded()) == packet)
    }

    @Test func decodesRRQWithOptions() {
        let bytes: [UInt8] = [0, 1] + Array("grubx64.efi\0octet\0BLKSIZE\u{0}1468\0tsize\u{0}0\0".utf8)
        #expect(TFTPPacket(buffer: ByteBuffer(bytes: bytes)) == .readRequest(
            filename: "grubx64.efi", mode: "octet",
            options: [TFTPOption(name: "blksize", value: "1468"), TFTPOption(name: "tsize", value: "0")]
        ))
    }

    @Test(arguments: [
        [0, 9, 0, 0],
        [0, 1] + Array("grubx64.efi\0octet".utf8),
        [0, 3, 0],
    ] as [[UInt8]])
    func rejectsMalformed(bytes: [UInt8]) {
        #expect(TFTPPacket(buffer: ByteBuffer(bytes: bytes)) == nil, "accepted \(bytes)")
    }
}
