import Foundation
import NIOCore
import ProvisionerNetbootXPC
import ProvisionerPXE
import Testing
@testable import ProvisionerNetbootCore

@Suite struct NetbootEventTests {
    let mac = MACAddress(bytes: [0x58, 0x47, 0xCA, 0x0A, 0x0B, 0x0C])!

    @Test func offeredCarriesLowercaseMACAndHexUUID() throws {
        let event = try #require(NetbootEvent(PXEEvent.offered(PXEClient(mac: mac, architecture: 7, uuid: [0xAB, 0x01]))))
        #expect(event == .offered(mac: "58:47:ca:0a:0b:0c", architecture: 7, uuid: "ab01"))
        #expect(try NetbootEvent(encoded: event.encoded()) == event)
    }

    @Test func failedOfferIsNotSentToPeers() throws {
        let failure = PXEOfferFailure(mac: mac, destination: try SocketAddress(ipAddress: "255.255.255.255", port: 68),
                                      interface: "en0", error: "unreachable")
        #expect(NetbootEvent(PXEEvent.offerFailed(failure)) == nil)
    }

    @Test func fileSentCarriesAddressAndOptionalMAC() throws {
        let known = NetbootEvent(PXEEvent.fileSent(TFTPDelivery(filename: "grub/grub.cfg", clientAddress: "10.0.0.7", mac: mac, bytes: 812)))
        #expect(known == .fileSent(filename: "grub/grub.cfg", clientAddress: "10.0.0.7", mac: "58:47:ca:0a:0b:0c", bytes: 812))
        let unknown = try #require(NetbootEvent(PXEEvent.fileSent(TFTPDelivery(filename: "vmlinuz", clientAddress: "10.0.0.8", mac: nil, bytes: 1))))
        #expect(try NetbootEvent(encoded: unknown.encoded()) == .fileSent(filename: "vmlinuz", clientAddress: "10.0.0.8", mac: nil, bytes: 1))
    }
}
