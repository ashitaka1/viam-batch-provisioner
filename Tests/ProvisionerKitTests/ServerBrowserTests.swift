import Foundation
@testable import ProvisionerKit
import Testing

@Test(arguments: [
    (["api": "v1"], true),
    (["api": "v1", "extra": "x"], true),
    (["api": "v2"], false),
    ([:], false),
    (["api": ""], false),
])
func txtFilter(txt: [String: String], accepted: Bool) {
    #expect(ServerBrowser.isProvisioner(txt: txt) == accepted, "TXT \(txt)")
}

@Test(arguments: [
    ("192.168.1.5", "http://192.168.1.5:8235/"),
    ("lab-mac.local", "http://lab-mac.local:8235/"),
    ("fe80::1%en0", "http://[fe80::1]:8235/"),
])
func baseURL(host: String, expected: String) {
    #expect(ServerBrowser.baseURL(host: host, port: 8235).absoluteString == expected)
}

@Test func manualServerIsNamedByAddress() {
    #expect(DiscoveredServer.manual(host: "10.0.0.2", port: 8235).name == "10.0.0.2:8235")
}
