import Testing
@testable import ProvisionerPXE

@Suite struct NetworkInterfaceTests {
    @Test func loopback() throws {
        let interface = try NetworkInterface.lookup("lo0")
        #expect(interface.index != 0)
        #expect(interface.mtu == 16384, "lo0 MTU \(interface.mtu)")
        #expect(interface.address == 0x7F00_0001, "lo0 address \(String(interface.address, radix: 16))")
    }
}
