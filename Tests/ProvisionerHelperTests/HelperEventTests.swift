import Foundation
import ProvisionerHelperXPC
import ProvisionerPXE
import Testing
@testable import ProvisionerHelperCore

@Suite struct HelperEventTests {
    let mac = MACAddress(bytes: [0x58, 0x47, 0xCA, 0x0A, 0x0B, 0x0C])!

    @Test func offeredCarriesLowercaseMACAndHexUUID() throws {
        let event = HelperEvent(PXEEvent.offered(PXEClient(mac: mac, architecture: 7, uuid: [0xAB, 0x01])))
        #expect(event == .offered(mac: "58:47:ca:0a:0b:0c", architecture: 7, uuid: "ab01"))
        #expect(try HelperEvent(encoded: event.encoded()) == event)
    }

    @Test func fileSentCarriesAddressAndOptionalMAC() throws {
        let known = HelperEvent(PXEEvent.fileSent(TFTPDelivery(filename: "grub/grub.cfg", clientAddress: "10.0.0.7", mac: mac, bytes: 812)))
        #expect(known == .fileSent(filename: "grub/grub.cfg", clientAddress: "10.0.0.7", mac: "58:47:ca:0a:0b:0c", bytes: 812))
        let unknown = HelperEvent(PXEEvent.fileSent(TFTPDelivery(filename: "vmlinuz", clientAddress: "10.0.0.8", mac: nil, bytes: 1)))
        #expect(try HelperEvent(encoded: unknown.encoded()) == .fileSent(filename: "vmlinuz", clientAddress: "10.0.0.8", mac: nil, bytes: 1))
    }
}
