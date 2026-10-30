import Testing
@testable import ProvisionerPXE

@Suite struct MACAddressTests {
    @Test func formatsLowercaseColon() {
        let mac = MACAddress(bytes: [0xAA, 0xBB, 0x0C, 0xDD, 0xEE, 0x01])
        #expect(mac?.description == "aa:bb:0c:dd:ee:01")
    }

    @Test(arguments: [[UInt8](repeating: 1, count: 5), [UInt8](repeating: 1, count: 7)])
    func rejectsWrongLength(bytes: [UInt8]) {
        #expect(MACAddress(bytes: bytes) == nil, "\(bytes.count) bytes accepted as a MAC")
    }
}
