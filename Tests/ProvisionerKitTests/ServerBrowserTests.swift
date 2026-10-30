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

@Test func ipv4URL() {
    #expect(ServerBrowser.baseURL(host: "192.168.1.5", port: 8235).absoluteString == "http://192.168.1.5:8235/")
}

@Test func ipv6URLIsBracketedWithoutScope() {
    #expect(ServerBrowser.baseURL(host: "fe80::1%en0", port: 8235).absoluteString == "http://[fe80::1]:8235/")
}

@Test func hostnameURL() {
    #expect(ServerBrowser.baseURL(host: "lab-mac.local", port: 8235).absoluteString == "http://lab-mac.local:8235/")
}

@Test func manualMatchesDiscoveredShape() {
    #expect(DiscoveredServer.manual(host: "10.0.0.2", port: 8235)
        == DiscoveredServer(name: "10.0.0.2:8235", baseURL: URL(string: "http://10.0.0.2:8235/")!))
}
