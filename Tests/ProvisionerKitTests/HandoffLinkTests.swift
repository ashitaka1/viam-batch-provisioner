import Foundation
@testable import ProvisionerKit
import Testing

@Test func linkRoundTrips() throws {
    let link = HandoffLink(host: "127.0.0.1", port: 54_321, nonce: .random())
    #expect(link.url.scheme == "viam-provisioner")
    #expect(try HandoffLink(url: link.url) == link)
    #expect(try HandoffLink(qrPayload: link.qrPayload) == link)
}

@Test func linkRoundTripsIPv6Host() throws {
    let link = HandoffLink(host: "fe80::1", port: 8000, nonce: .random())
    #expect(try HandoffLink(url: link.url) == link)
}

@Test(arguments: [
    "https://handoff?host=127.0.0.1&port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://other?host=127.0.0.1&port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://handoff?port=5000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://handoff?host=127.0.0.1&port=0&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://handoff?host=127.0.0.1&port=70000&nonce=AAAAAAAAAAAAAAAAAAAAAA",
    "viam-provisioner://handoff?host=127.0.0.1&port=5000&nonce=short",
    "viam-provisioner://handoff?host=127.0.0.1&port=5000",
])
func linkRejectsMissingOrBadFields(string: String) {
    #expect(throws: HandoffError.invalidLink, "\(string)") { try HandoffLink(url: URL(string: string)!) }
}
