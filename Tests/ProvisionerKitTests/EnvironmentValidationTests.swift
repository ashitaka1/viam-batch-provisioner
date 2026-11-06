import Foundation
@testable import ProvisionerKit
import Testing

let testKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGwh65eWecsGh+Pz9iCG86FW9YrBfPOneq5KBLuGdhnG test@example"
let testKeyFingerprint = "SHA256:awQvRrCB8fy5WoOAImPJ2/B0v6sZg24inBfmyhqV0k0"

/// A full-mode environment with no problems.
func validEnvironment() -> Environment {
    var env = Environment.new(name: "Shop")
    env.orgID = "org-1"
    env.orgName = "Acme"
    env.locationID = "loc-1"
    env.locationName = "Lab"
    env.namePrefix = "shop"
    env.sshPublicKey = testKey
    env.timezone = "America/New_York"
    env.hasPassword = true
    return env
}

private func fields(_ env: Environment, otherNames: [String] = [], secrets: EnvironmentSecrets? = nil) -> [EnvironmentField] {
    env.problems(otherNames: otherNames, secrets: secrets).map(\.field)
}

private func messages(_ env: Environment, _ field: EnvironmentField, secrets: EnvironmentSecrets? = nil) -> [String] {
    env.problems(otherNames: [], secrets: secrets).filter { $0.field == field }.map(\.message)
}

@Suite struct EnvironmentValidationTests {
    @Test func validEnvironmentHasNoProblems() {
        #expect(fields(validEnvironment()) == [])
    }

    @Test func newEnvironmentNeedsOrgLocationPrefixKeyAndPassword() {
        let env = Environment.new(name: "New Environment")
        #expect(Set(fields(env)) == [.org, .location, .namePrefix, .sshPublicKey, .password])
        #expect(messages(env, .org) == ["Choose an organization."])
        #expect(messages(env, .location) == ["Choose a location."])
        #expect(messages(env, .namePrefix) == ["Enter a name prefix."])
        #expect(messages(env, .password) == ["Enter a password for the machines' account."])
    }

    @Test func newEnvironmentDefaults() {
        let env = Environment.new(name: "lab")
        #expect(env.namePrefix == "lab", "a name that passes Viam's rule becomes the prefix")
        #expect(env.provisionMode == .full)
        #expect(env.username == "viam")
        #expect(env.timezone == TimeZone.current.identifier)
    }

    /// Only full mode creates machines in Viam; every mode names machines from the prefix.
    @Test(arguments: [ProvisionMode.agent, .osOnly])
    func modesWithoutViamNeedPrefixButNoOrg(_ mode: ProvisionMode) {
        var env = validEnvironment()
        env.provisionMode = mode
        env.orgID = nil
        env.locationID = nil
        #expect(fields(env) == [])
        env.namePrefix = ""
        #expect(fields(env) == [.namePrefix])
    }

    @Test func nameEmptyOrDuplicate() {
        var env = validEnvironment()
        env.name = "  "
        #expect(fields(env) == [.name])
        #expect(fields(validEnvironment(), otherNames: ["shop"]) == [.name])
    }

    @Test func prefixUsesViamNameRule() {
        var env = validEnvironment()
        env.namePrefix = "bad_prefix"
        #expect(messages(env, .namePrefix) == MachineName.prefixProblems("bad_prefix"))
        #expect(messages(env, .namePrefix).first?.contains("\"_\"") == true)
    }

    @Test(arguments: ["Viam", "1viam", "root", "", String(repeating: "a", count: 33)])
    func usernameRefused(_ username: String) {
        var env = validEnvironment()
        env.username = username
        #expect(fields(env) == [.username])
    }

    @Test func usernameMessageNamesTheRule() {
        var env = validEnvironment()
        env.username = "Viam"
        #expect(messages(env, .username) == ["Usernames are lowercase letters, digits, _ and -, starting with a letter or _, up to 32 characters."])
    }

    @Test(arguments: ["viam", "_svc", "ops-1", String(repeating: "a", count: 32)])
    func usernameAccepted(_ username: String) {
        var env = validEnvironment()
        env.username = username
        #expect(fields(env) == [])
    }

    @Test func sshKeyMessages() {
        var env = validEnvironment()
        env.sshPublicKey = ""
        #expect(messages(env, .sshPublicKey) == ["Choose an SSH public key so you can log in to the machines."])
        env.sshPublicKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
        #expect(messages(env, .sshPublicKey) == ["That's a private key. Choose the matching .pub file."])
        env.sshPublicKey = testKey + "\n" + testKey
        #expect(messages(env, .sshPublicKey) == ["This isn't an OpenSSH public key."])
        env.sshPublicKey = "ssh-ed25519 not*base64"
        #expect(messages(env, .sshPublicKey) == ["This isn't an OpenSSH public key."])
    }

    @Test func sshKeyWhoseBlobNamesAnotherTypeIsRefused() {
        let blob = testKey.split(separator: " ")[1]
        #expect(throws: SSHKeyProblem.notPublicKey) { try SSHPublicKey.parse("ssh-rsa \(blob)").get() }
    }

    @Test func sshKeyParsesTypeCommentAndFingerprint() throws {
        let key = try SSHPublicKey.parse(testKey + "\n").get()
        #expect(key.type == "ssh-ed25519")
        #expect(key.comment == "test@example")
        #expect(key.fingerprint == testKeyFingerprint)
    }

    @Test func timezoneMustBeKnown() {
        var env = validEnvironment()
        env.timezone = "Mars/Olympus"
        #expect(fields(env) == [.timezone])
    }

    @Test func wifiPasswordNeedsSSID() {
        var env = validEnvironment()
        env.hasWifiPassword = true
        #expect(messages(env, .wifiPassword) == ["Enter the network name, or clear the password."])
    }

    @Test func wifiSSIDAtMost32Bytes() {
        var env = validEnvironment()
        env.wifiSSID = String(repeating: "é", count: 17)
        #expect(messages(env, .wifiSSID) == ["WiFi network names are at most 32 bytes."])
        env.wifiSSID = String(repeating: "é", count: 16)
        #expect(messages(env, .wifiSSID) == [])
    }

    @Test(arguments: [("1234567", false), ("12345678", true), (String(repeating: "a", count: 63), true),
                      (String(repeating: "g", count: 64), false), (String(repeating: "ab", count: 32), true),
                      (String(repeating: "é", count: 32), false), ("éééé", true)])
    func wifiPasswordLength(_ password: String, _ accepted: Bool) {
        var env = validEnvironment()
        env.wifiSSID = "shop"
        env.hasWifiPassword = true
        let found = messages(env, .wifiPassword, secrets: EnvironmentSecrets(passwordHash: "$6$x$y", wifiPassword: password))
        #expect(found == (accepted ? [] : ["WiFi passwords are 8 to 63 characters."]))
    }

    @Test func packageNamesFollowDebianRule() {
        var env = validEnvironment()
        env.packages = ["curl", "Bad Name"]
        #expect(messages(env, .packages) == [
            "Line 2: \"Bad Name\" isn't an apt package name; names are lowercase letters, digits, + - and ., at least 2 characters.",
        ])
        env.packages = ["curl", "libstdc++6", "curl"]
        #expect(messages(env, .packages) == ["Line 3 repeats curl."])
        env.packages = ["a", "-ab"]
        #expect(messages(env, .packages).count == 2, "names are at least 2 characters and start with a letter or digit")
    }

    @Test func configCarriesEverySetting() throws {
        var env = validEnvironment()
        env.provisionMode = .agent
        env.username = "ops"
        env.packages = ["curl", "jq"]
        env.wifiSSID = "shop"
        env.wifiCountry = "GB"
        env.hasWifiPassword = true
        env.hasTailscaleKey = true
        let hash = SHA512Crypt.hash("hunter22")
        let config = try env.config(secrets: EnvironmentSecrets(passwordHash: hash, wifiPassword: "wifipass1", tailscaleAuthKey: "tskey-1"))
        #expect(config.provisionMode == .agent)
        #expect(config.username == "ops")
        #expect(config.sshPublicKey == testKey)
        #expect(config.timezone == "America/New_York")
        #expect(config.packages == ["curl", "jq"])
        #expect(config.wifi == EnvironmentConfig.Wifi(ssid: "shop", password: "wifipass1", country: "GB"))
        #expect(config.tailscaleAuthKey == "tskey-1")
        #expect(config.passwordHash == hash)
    }

    @Test func configWithoutWifiOrTailscaleOmitsThem() throws {
        let config = try validEnvironment().config(secrets: EnvironmentSecrets(passwordHash: "$6$x$y"))
        #expect(config.wifi == nil)
        #expect(config.tailscaleAuthKey == nil)
    }

    @Test func configRefusesInvalidEnvironment() {
        var env = validEnvironment()
        env.namePrefix = ""
        #expect(throws: EnvironmentError.invalid([EnvironmentProblem(field: .namePrefix, message: "Enter a name prefix.")])) {
            try env.config(secrets: EnvironmentSecrets(passwordHash: "$6$x$y"))
        }
    }

    @Test func configRefusesMissingPasswordSecret() {
        #expect(throws: EnvironmentError.invalid([EnvironmentProblem(field: .password, message: "Enter a password for the machines' account.")])) {
            try validEnvironment().config(secrets: EnvironmentSecrets())
        }
    }

    @Test func configTrimsTheSSHKey() throws {
        var env = validEnvironment()
        env.sshPublicKey = testKey + "\n"
        #expect(try env.config(secrets: EnvironmentSecrets(passwordHash: "$6$x$y")).sshPublicKey == testKey)
    }

    @Test func configTreatsEmptyValuesAsAbsent() throws {
        var env = validEnvironment()
        env.wifiSSID = "shop"
        var config = try env.config(secrets: EnvironmentSecrets(passwordHash: "$6$x$y", wifiPassword: "", tailscaleAuthKey: ""))
        #expect(config.wifi == EnvironmentConfig.Wifi(ssid: "shop", password: nil, country: env.wifiCountry))
        #expect(config.tailscaleAuthKey == nil)
        env.wifiSSID = ""
        config = try env.config(secrets: EnvironmentSecrets(passwordHash: "$6$x$y"))
        #expect(config.wifi == nil)
    }

    @Test func secretsDescriptionHidesValues() {
        let secrets = EnvironmentSecrets(passwordHash: "$6$salt$hashvalue", wifiPassword: "wifipass1", tailscaleAuthKey: "tskey-1")
        for text in [String(describing: secrets), String(reflecting: secrets)] {
            #expect(!text.contains("hashvalue") && !text.contains("wifipass1") && !text.contains("tskey-1"))
        }
    }

    @Test func sshDirectoryListsParsablePubKeysByName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (testKey + "\n").write(to: dir.appendingPathComponent("z_ed25519.pub"), atomically: true, encoding: .utf8)
        try testKey.write(to: dir.appendingPathComponent("a.pub"), atomically: true, encoding: .utf8)
        try "garbage".write(to: dir.appendingPathComponent("broken.pub"), atomically: true, encoding: .utf8)
        try testKey.write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        let keys = SSHKeyDirectory.keys(in: dir)
        #expect(keys.map(\.file.lastPathComponent) == ["a.pub", "z_ed25519.pub"])
        #expect(keys.first?.text == testKey)
        #expect(keys.first?.key.fingerprint == testKeyFingerprint)
        #expect(SSHKeyDirectory.keys(in: dir.appendingPathComponent("missing")).isEmpty)
    }
}
