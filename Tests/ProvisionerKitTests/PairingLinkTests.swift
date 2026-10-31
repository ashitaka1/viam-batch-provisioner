import Foundation
@testable import ProvisionerKit
import Testing

@Test func linkRoundTrips() throws {
    let link = PairingLink(host: "127.0.0.1", port: 54_321, nonce: .random())
    #expect(link.url.scheme == "viam-provisioner")
    #expect(try PairingLink(url: link.url) == link)
    #expect(try PairingLink(qrPayload: link.qrPayload) == link)
}

@Test func linkRoundTripsIPv6Host() throws {
    let link = PairingLink(host: "fe80::1", port: 8000, nonce: .random())
    #expect(try PairingLink(url: link.url) == link)
}

@Test(arguments: [
    "https://pair?host=127.0.0.1&port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://other?host=127.0.0.1&port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://pair?port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://pair?host=127.0.0.1&port=0&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://pair?host=127.0.0.1&port=70000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://pair?host=127.0.0.1&port=5000&nonce=short",
    "viam-provisioner://pair?host=127.0.0.1&port=5000",
])
func linkRejectsMissingOrBadFields(string: String) {
    #expect(throws: PairingError.invalidLink, "\(string)") { try PairingLink(url: URL(string: string)!) }
}
