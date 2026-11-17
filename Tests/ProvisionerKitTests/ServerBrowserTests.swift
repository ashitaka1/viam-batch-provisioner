import Foundation
import Network
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
    ("[::1]", "http://[::1]:8235/"),
    (" 10.0.0.2 ", "http://10.0.0.2:8235/"),
])
func baseURL(host: String, expected: String) {
    #expect(ServerBrowser.baseURL(host: host, port: 8235)?.absoluteString == expected)
}

@Test(arguments: ["", "my server", "host/path", "host?x", "user@host", "[::1"])
func manualAddressRejectsWhatIsNotAHost(host: String) {
    #expect(DiscoveredServer.manual(host: host, port: 8235) == nil, "host \(host)")
}

@Test(arguments: [0, -1, 65536])
func manualAddressRejectsPortsOutOfRange(port: Int) {
    #expect(DiscoveredServer.manual(host: "10.0.0.2", port: port) == nil, "port \(port)")
}

@Test func manualServerIsNamedByAddress() {
    #expect(DiscoveredServer.manual(host: "10.0.0.2", port: 8235)?.name == "10.0.0.2:8235")
}

@Test func readyBrowserPublishesEvenWhenEmpty() {
    #expect(ServerBrowser.outcome(of: .ready) == .publish)
}

@Test(arguments: [
    NWBrowser.State.failed(.posix(.ENETDOWN)),
    NWBrowser.State.waiting(.dns(-65555)),
])
func browserFailureEndsTheStream(state: NWBrowser.State) {
    #expect(ServerBrowser.outcome(of: state) != .publish && ServerBrowser.outcome(of: state) != .none,
            "state \(state) should fail the browse")
}

private let resolved = URL(string: "http://192.168.1.5:8235/")!

/// Answers `/status` per host: the address the server advertises, or a failure for a host that doesn't answer.
private func statuses(_ answers: [String: String?]) -> @Sendable (URL) async throws -> String? {
    { url in
        guard let answer = answers[url.host()!] else { throw URLError(.cannotConnectToHost) }
        return answer
    }
}

@Test func advertisedHostIsUsedOnTheAPIPortWhenItAnswers() async {
    let url = await ServerBrowser.preferredURL(
        resolved: resolved,
        status: statuses(["192.168.1.5": "10.0.0.1:8234", "10.0.0.1": "10.0.0.1:8234"]))

    #expect(url == URL(string: "http://10.0.0.1:8235/"))
}

@Test func resolvedAddressIsKeptWhenTheAdvertisedHostDoesNotAnswer() async {
    let url = await ServerBrowser.preferredURL(
        resolved: resolved, status: statuses(["192.168.1.5": "10.0.0.1:8234"]))

    #expect(url == resolved)
}

@Test func resolvedAddressIsKeptWhenTheServerAdvertisesNone() async {
    let url = await ServerBrowser.preferredURL(resolved: resolved, status: statuses(["192.168.1.5": nil]))

    #expect(url == resolved)
}

@Test(arguments: ["", "not a host:8234"])
func resolvedAddressIsKeptWhenTheAdvertisedAddressDoesNotParse(address: String) async {
    let url = await ServerBrowser.preferredURL(resolved: resolved, status: statuses(["192.168.1.5": address]))

    #expect(url == resolved, "address \(address)")
}
