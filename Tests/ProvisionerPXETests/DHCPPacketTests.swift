import NIOCore
import Testing
@testable import ProvisionerPXE

@Suite struct DHCPPacketTests {
    @Test func roundTrips() {
        let discover = pxeDiscover()
        #expect(DHCPPacket(buffer: discover.encoded()) == discover)
    }

    /// Field offsets from RFC 2131 figure 1, written out by hand.
    @Test func encodesAtRFCOffsets() {
        var packet = pxeDiscover()
        packet.op = 2
        packet.yiaddr = 0x0A00_0001
        packet.siaddr = 0xC0A8_0705
        packet.file = "grubx64.efi"
        packet.options = [DHCPOption(code: 53, data: [2])]
        let bytes = Array(packet.encoded().readableBytesView)

        #expect(bytes[0] == 2)
        #expect(Array(bytes[4..<8]) == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(Array(bytes[16..<20]) == [10, 0, 0, 1], "yiaddr")
        #expect(Array(bytes[20..<24]) == [192, 168, 7, 5], "siaddr")
        #expect(Array(bytes[28..<34]) == fixtureMAC)
        #expect(Array(bytes[108..<119]) == Array("grubx64.efi".utf8))
        #expect(bytes[119] == 0)
        #expect(Array(bytes[236..<240]) == [99, 130, 83, 99])
        #expect(Array(bytes[240...]) == [53, 1, 2, 255])
    }

    @Test func parsesForgedDiscover() throws {
        var bytes: [UInt8] = [1, 1, 6, 0]          // op, htype, hlen, hops
        bytes += [0x12, 0x34, 0x56, 0x78]          // xid
        bytes += [0, 0, 0x80, 0]                   // secs, flags
        bytes += [UInt8](repeating: 0, count: 16)  // ciaddr yiaddr siaddr giaddr
        bytes += fixtureMAC + [UInt8](repeating: 0, count: 10)
        bytes += [UInt8](repeating: 0, count: 64 + 128)
        bytes += [99, 130, 83, 99]
        bytes += [53, 1, 1]
        let vendor = Array("PXEClient:Arch:00007".utf8)
        bytes += [60, UInt8(vendor.count)] + vendor
        bytes += [0]                               // pad
        bytes += [93, 2, 0, 7]
        bytes += [97, 17, 0] + fixtureUUID
        bytes += [255]

        let packet = try #require(DHCPPacket(buffer: ByteBuffer(bytes: bytes)))
        #expect(packet.xid == 0x1234_5678)
        #expect(packet.messageType == 1)
        #expect(packet.clientMAC == MACAddress(bytes: fixtureMAC))
        #expect(packet.option(93) == [0, 7])
        #expect(packet.option(60) == vendor)
    }

    @Test(arguments: malformedPackets)
    func rejectsMalformed(bytes: [UInt8]) {
        #expect(DHCPPacket(buffer: ByteBuffer(bytes: bytes)) == nil, "accepted \(bytes.count) bytes")
    }
}

private let malformedPackets: [[UInt8]] = {
    let header = [UInt8](repeating: 0, count: 236)
    let cookie: [UInt8] = [99, 130, 83, 99]
    return [
        [UInt8](repeating: 1, count: 100),
        header + [1, 2, 3, 4],
        header + cookie + [60, 20, 1, 2, 3],
        header + cookie + [60],
    ]
}()
