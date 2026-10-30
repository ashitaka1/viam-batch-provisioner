import NIOCore
import Testing
@testable import ProvisionerPXE

@Suite struct DHCPPacketTests {
    @Test func roundTrips() {
        let discover = pxeDiscover()
        #expect(DHCPPacket(buffer: discover.encoded()) == discover)
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

    @Test(arguments: truncatedPackets)
    func rejectsTruncated(bytes: [UInt8]) {
        #expect(DHCPPacket(buffer: ByteBuffer(bytes: bytes)) == nil, "accepted \(bytes.count) bytes")
    }
}

private let truncatedPackets: [[UInt8]] = {
    let header = [UInt8](repeating: 0, count: 236)
    let cookie: [UInt8] = [99, 130, 83, 99]
    return [
        [UInt8](repeating: 1, count: 100),
        header + [1, 2, 3, 4],
        header + cookie + [60, 20, 1, 2, 3],
    ]
}()
