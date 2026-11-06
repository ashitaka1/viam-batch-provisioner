import Testing
@testable import ProvisionerPXE

private func discover(option93: [UInt8]) -> DHCPPacket {
    var packet = pxeDiscover()
    packet.options = packet.options.map { $0.code == 93 ? DHCPOption(code: 93, data: option93) : $0 }
    return packet
}

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

    @Test func learnsLeaseFromRequestedAddress() throws {
        let request = pxeDiscover(messageType: 3, requestedAddress: 0xC0A8_0742)
        let lease = try #require(responder.lease(in: request))
        #expect(lease.address == 0xC0A8_0742)
        #expect(lease.mac == MACAddress(bytes: fixtureMAC))
    }

    @Test func learnsLeaseFromClientAddress() throws {
        let lease = try #require(responder.lease(in: pxeDiscover(messageType: 3, ciaddr: 0xC0A8_0743)))
        #expect(lease.address == 0xC0A8_0743)
        #expect(lease.mac == MACAddress(bytes: fixtureMAC))
    }

    @Test func requestedAddressWinsOverClientAddress() throws {
        let request = pxeDiscover(messageType: 3, ciaddr: 0xC0A8_0743, requestedAddress: 0xC0A8_0742)
        #expect(try #require(responder.lease(in: request)).address == 0xC0A8_0742)
    }

    @Test func noLeaseFromMalformedOrRelayedRequest() {
        var malformed = pxeDiscover(messageType: 3)
        malformed.options.append(DHCPOption(code: 50, data: [192, 168, 7]))
        #expect(responder.lease(in: malformed) == nil, "a 3-byte option 50")
        #expect(responder.lease(in: pxeDiscover(messageType: 3, giaddr: 0x0A00_0001, requestedAddress: 0xC0A8_0742)) == nil, "a relayed request")
    }

    @Test func noLeaseWithoutAddressOrFromDiscover() {
        #expect(responder.lease(in: pxeDiscover(messageType: 3)) == nil, "a request naming no address")
        #expect(responder.lease(in: pxeDiscover(requestedAddress: 0xC0A8_0742)) == nil, "a discover")
        #expect(responder.lease(in: pxeDiscover(vendorClass: "MSFT 5.0", messageType: 3, requestedAddress: 0xC0A8_0742)) == nil,
                "a request from a non-PXE client")
    }

    @Test func acceptsArch9() {
        #expect(responder.reply(to: pxeDiscover(arch: 9), on: .dhcp) != nil)
    }

    /// RFC 4578 section 2.1: option 93 is a list of 16-bit architecture types.
    @Test(arguments: [([0, 0, 0, 7], 7), ([0, 11, 0, 9], 9), ([0, 9, 0, 7], 9)] as [([UInt8], UInt16)])
    func answersArchitectureList(list: [UInt8], reported: UInt16) throws {
        let (_, client) = try #require(responder.reply(to: discover(option93: list), on: .dhcp))
        #expect(client?.architecture == reported)
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
        ("odd-length option 93", discover(option93: [0, 7, 0]), .dhcp),
        ("empty option 93", discover(option93: []), .dhcp),
        ("list without x86-64 UEFI", discover(option93: [0, 0, 0, 11]), .dhcp),
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
