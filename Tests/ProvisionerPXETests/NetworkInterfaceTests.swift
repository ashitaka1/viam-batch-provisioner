import Testing
@testable import ProvisionerPXE

@Suite struct NetworkInterfaceTests {
    @Test func loopback() throws {
        let interface = try NetworkInterface.lookup("lo0")
        #expect(interface.index != 0)
        #expect(interface.mtu == 16384, "lo0 MTU \(interface.mtu)")
        #expect(interface.address == 0x7F00_0001, "lo0 address \(String(interface.address, radix: 16))")
    }

    @Test func noIPv4Throws() {
        #expect(throws: PXEServerError.interfaceHasNoIPv4("en9")) {
            try NetworkInterface(name: "en9", index: 9, addresses: [.link(mtu: 1500)])
        }
    }

    @Test func firstIPv4AndLinkMTU() throws {
        let interface = try NetworkInterface(
            name: "en9", index: 9, addresses: [.ipv4(0x0A00_0001), .link(mtu: 9000), .ipv4(0x0A00_0002)])
        #expect(interface.address == 0x0A00_0001, "address \(String(interface.address, radix: 16))")
        #expect(interface.mtu == 9000)
    }

    @Test func mtuDefaultsWithoutLinkEntry() throws {
        #expect(try NetworkInterface(name: "en9", index: 9, addresses: [.ipv4(0x0A00_0001)]).mtu == 1500)
    }
}
