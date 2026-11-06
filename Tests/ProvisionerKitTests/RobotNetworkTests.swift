import Foundation
@testable import ProvisionerKit
import Testing

private func robotProblems(_ env: Environment) -> [EnvironmentProblem] {
    env.problems(otherNames: []).filter { $0.field == .robotNetAddress || $0.field == .robotNetPort }
}

@Suite struct RobotNetworkTests {
    @Test func newEnvironmentHasTheDefaultRobotNetworkOnAnyPort() {
        let env = Environment.new(name: "lab")
        #expect(env.robotNetEnabled)
        #expect(env.robotNetAddress == "192.168.20.1/24")
        #expect(env.robotNetPort == nil)
        #expect(robotProblems(env) == [])
    }

    @Test(arguments: ["192.168.20.1/24", "10.0.0.1/8", "10.255.255.254/30", "172.16.0.1/12", "172.31.9.9/16",
                      "192.168.0.1/32", "10.1.2.3/0"])
    func privateAddressesWithAnyPrefixAreAccepted(_ address: String) {
        var env = validEnvironment()
        env.robotNetAddress = address
        #expect(robotProblems(env) == [])
    }

    @Test(arguments: ["8.8.8.8/24", "172.15.0.1/16", "172.32.0.1/16", "192.169.0.1/24", "192.168.20.1",
                      "192.168.20.1/33", "192.168.256.1/24", "192.168.020.1/24", "", "none", " 10.0.0.1/8"])
    func otherAddressesAreRefused(_ address: String) {
        var env = validEnvironment()
        env.robotNetAddress = address
        #expect(robotProblems(env).map(\.field) == [.robotNetAddress])
    }

    @Test(arguments: ["enp3s0x123456789", "en p3", "enp3s0;reboot", "enp3/0"])
    func portsLinuxCouldNotNameAreRefused(_ port: String) {
        var env = validEnvironment()
        env.robotNetPort = port
        #expect(robotProblems(env).map(\.field) == [.robotNetPort])
    }

    @Test func switchedOffItsSettingsRaiseNoProblems() {
        var env = validEnvironment()
        env.robotNetEnabled = false
        env.robotNetAddress = "8.8.8.8/24"
        env.robotNetPort = "en p3"
        #expect(robotProblems(env) == [])
    }

    @Test func configCarriesTheAddressAndPortOrNone() throws {
        let secrets = EnvironmentSecrets(passwordHash: "$6$x$y")
        var env = validEnvironment()
        var config = try env.config(secrets: secrets)
        #expect((config.robotNetAddress, config.robotNetPort) == ("192.168.20.1/24", nil))

        env.robotNetAddress = "10.20.0.1/16"
        env.robotNetPort = "enp3s0"
        config = try env.config(secrets: secrets)
        #expect((config.robotNetAddress, config.robotNetPort) == ("10.20.0.1/16", "enp3s0"))

        env.robotNetPort = ""
        #expect(try env.config(secrets: secrets).robotNetPort == nil)

        env.robotNetEnabled = false
        env.robotNetPort = "enp3s0"
        config = try env.config(secrets: secrets)
        #expect((config.robotNetAddress, config.robotNetPort) == ("none", nil))
    }

    @Test func anEnvironmentSavedBeforeTheRobotNetworkSettingsReadsAsTheDefault() throws {
        var env = validEnvironment()
        env.robotNetAddress = "10.0.0.1/8"
        env.robotNetPort = "enp3s0"
        env.robotNetEnabled = false
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(env)) as? [String: Any])
        for key in ["robotNetEnabled", "robotNetAddress", "robotNetPort"] {
            #expect(json.removeValue(forKey: key) != nil, "the file has no \(key)")
        }

        let read = try JSONDecoder().decode(Environment.self, from: JSONSerialization.data(withJSONObject: json))

        var expected = env
        expected.robotNetEnabled = true
        expected.robotNetAddress = "192.168.20.1/24"
        expected.robotNetPort = nil
        #expect(read == expected)
    }

    @Test func savedSettingsRoundTrip() throws {
        var env = validEnvironment()
        env.robotNetEnabled = false
        env.robotNetAddress = "10.0.0.1/8"
        env.robotNetPort = "enp3s0"
        #expect(try JSONDecoder().decode(Environment.self, from: JSONEncoder().encode(env)) == env)
    }
}
