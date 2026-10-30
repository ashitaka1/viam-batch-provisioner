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

    @Test(arguments: [
        (TFTPPacket.ack(block: 1), [0, 4, 0, 1]),
        (.data(block: 258, payload: ByteBuffer(bytes: [7, 8])), [0, 3, 1, 2, 7, 8]),
        (.optionAck([TFTPOption(name: "tsize", value: "1234")]), [0, 6] + Array("tsize\u{0}1234\u{0}".utf8)),
        (.error(code: 1, message: "File not found"), [0, 5, 0, 1] + Array("File not found\u{0}".utf8)),
    ] as [(TFTPPacket, [UInt8])])
    func encodesRFCBytes(packet: TFTPPacket, bytes: [UInt8]) {
        #expect(Array(packet.encoded().readableBytesView) == bytes)
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
