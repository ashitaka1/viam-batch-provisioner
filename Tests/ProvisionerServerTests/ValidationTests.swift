@testable import ProvisionerServer
import Testing

@Test(arguments: [
    ("robot-1", 0), ("a", 0), ("A1-b2", 0), (String(repeating: "a", count: 60), 0),
    ("", 1), ("-", 1), ("-a", 1), ("a-", 1), ("a b", 1), ("café", 1), ("a_b", 1),
    (String(repeating: "a", count: 61), 1), ("-a b-", 3),
])
func nameRule(name: String, problemCount: Int) {
    #expect(nameProblems(name).count == problemCount, "\(name): \(nameProblems(name))")
}

@Test func environmentProblemsNameEachBrokenRule() {
    let broken = Schemas.Environment(provisionMode: .full, username: "Root!", passwordHash: "$6$x$y",
                                     sshPublicKey: "ssh-ed25519 AAAA\nx", timezone: "../etc", packages: ["curl", "Bad Pkg"],
                                     wifi: .init(ssid: "lab\u{2028}", password: "p"), robotNetAddress: "8.8.8.8/24",
                                     robotNetPort: "-x")
    #expect(environmentProblems(broken).map(\.field) ==
            ["username", "ssh_public_key", "timezone", "packages", "wifi.ssid", "robot_net_address", "robot_net_port"])
    #expect(environmentProblems(validEnvironment()).isEmpty)
}

@Test(arguments: ["none", "10.0.0.1/8", "172.16.5.1/12", "192.168.20.1/24"])
func robotNetAddressAccepted(address: String) {
    var environment = validEnvironment()
    environment.robotNetAddress = address
    #expect(environmentProblems(environment).isEmpty)
}

@Test(arguments: ["8.8.8.8/24", "172.32.0.1/12", "192.168.1.1", "192.168.1.300/24", "192.168.1.1/33", "$(x)"])
func robotNetAddressRefused(address: String) {
    var environment = validEnvironment()
    environment.robotNetAddress = address
    #expect(environmentProblems(environment).map(\.field) == ["robot_net_address"])
}
