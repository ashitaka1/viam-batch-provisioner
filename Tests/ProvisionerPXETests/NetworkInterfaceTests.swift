import Darwin
import Testing
@testable import ProvisionerPXE

@Suite struct NetworkInterfaceTests {
    @Test func loopback() throws {
        let interface = try NetworkInterface.lookup("lo0")
        #expect(interface.index == if_nametoindex("lo0"))
        #expect(interface.address == 0x7F00_0001, "lo0 address \(String(interface.address, radix: 16))")
    }

    @Test func unknown() {
        #expect(throws: PXEServerError.interfaceNotFound("nope9")) {
            try NetworkInterface.lookup("nope9")
        }
    }
}
