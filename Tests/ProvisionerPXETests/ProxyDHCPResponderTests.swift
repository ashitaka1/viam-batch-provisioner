import Testing
@testable import ProvisionerPXE

@Suite struct ProxyDHCPResponderTests {
    let server: UInt32 = 0xC0A8_0705  // 192.168.7.5
    var responder: ProxyDHCPResponder {
        ProxyDHCPResponder(serverAddress: server, bootFilename: "grubx64.efi")
    }

    @Test func offersBootFile() throws {
        let discover = pxeDiscover()
        let (offer, client) = try #require(responder.reply(to: discover, on: .dhcp))

        #expect(offer.op == 2)
        #expect(offer.xid == discover.xid)
        #expect(offer.flags == discover.flags)
        #expect(offer.chaddr == discover.chaddr)
        #expect(offer.yiaddr == 0)
        #expect(offer.siaddr == server)
        #expect(offer.file == "grubx64.efi")
        #expect(offer.messageType == 2)
        #expect(offer.option(54) == [192, 168, 7, 5])
        #expect(offer.option(60) == Array("PXEClient".utf8))
        #expect(offer.option(97) == [0] + fixtureUUID)
        #expect(offer.option(43) == [6, 1, 8, 255], "PXE_DISCOVERY_CONTROL must tell the client to use the boot file")
        #expect(client == PXEClient(mac: MACAddress(bytes: fixtureMAC)!, architecture: 7, uuid: fixtureUUID))
    }

    @Test func acksOnPXEPort() throws {
        let (ack, client) = try #require(responder.reply(to: pxeDiscover(messageType: 3), on: .pxe))
        #expect(ack.messageType == 5)
        #expect(ack.file == "grubx64.efi")
        #expect(ack.siaddr == server)
        #expect(ack.option(43) == [6, 1, 8, 255])
        #expect(client == nil, "only discovers are reported")
    }

    @Test func acceptsArch9() {
        #expect(responder.reply(to: pxeDiscover(arch: 9), on: .dhcp) != nil)
    }

    @Test(arguments: [
        ("no option 60", pxeDiscover(vendorClass: nil), DHCPListener.dhcp),
        ("Windows vendor class", pxeDiscover(vendorClass: "MSFT 5.0"), .dhcp),
        ("BIOS", pxeDiscover(arch: 0), .dhcp),
        ("ARM64 UEFI", pxeDiscover(arch: 11), .dhcp),
        ("relayed", pxeDiscover(giaddr: 0x0A00_0001), .dhcp),
        ("request on 67", pxeDiscover(messageType: 3), .dhcp),
        ("discover on 4011", pxeDiscover(), .pxe),
        ("server reply", { var p = pxeDiscover(); p.op = 2; return p }(), .dhcp),
        ("no option 93", { var p = pxeDiscover(); p.options.removeAll { $0.code == 93 }; return p }(), .dhcp),
        ("short option 93", { var p = pxeDiscover(); p.options = p.options.map { $0.code == 93 ? DHCPOption(code: 93, data: [7]) : $0 }; return p }(), .dhcp),
        ("not Ethernet", { var p = pxeDiscover(); p.htype = 6; return p }(), .dhcp),
        ("long hardware address", { var p = pxeDiscover(); p.hlen = 8; return p }(), .dhcp),
    ])
    func ignores(label: String, packet: DHCPPacket, listener: DHCPListener) {
        #expect(responder.reply(to: packet, on: listener) == nil, "answered: \(label)")
    }

    @Test func malformedUUIDNotReported() throws {
        var discover = pxeDiscover()
        discover.options = discover.options.map { $0.code == 97 ? DHCPOption(code: 97, data: [0, 1, 2]) : $0 }
        let (_, client) = try #require(responder.reply(to: discover, on: .dhcp))
        #expect(client?.uuid == nil)
    }

    @Test func noUUID() throws {
        let (offer, client) = try #require(responder.reply(to: pxeDiscover(uuid: nil), on: .dhcp))
        #expect(offer.option(97) == nil)
        #expect(client?.uuid == nil)
    }
}
