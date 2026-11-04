import Foundation
@testable import ProvisionerKit
import Testing

private let tcos = """
# Environment: tcos
# OS account
USERNAME=ops
PASSWORD=hunter22

WIFI_SSID="Rivendell"
WIFI_PASSWORD='mellon-friend'
WIFI_COUNTRY=GB
TIMEZONE=Europe/London
SSH_PUBLIC_KEY_FILE=~/.ssh/id_ed25519.pub
PROVISION_MODE=agent
VIAM_API_KEY_ID=key-id
VIAM_API_KEY=key-secret
VIAM_ORG_ID=org-1
VIAM_LOCATION_ID=loc-1
TAILSCALE_AUTH_KEY=tskey-1
"""

private let packagesText = """
# Default apt packages
curl

# Tools
jq
"""

private func importing(_ text: String = tcos, packages: String? = packagesText,
                       files: [String: String] = ["/Users/test/.ssh/id_ed25519.pub": testKey + "\n"]) throws -> (Environment, EnvironmentSecrets) {
    try SiteEnvImport.environment(name: "tcos", settings: SiteEnv.parse(text), packagesText: packages,
                                  readFile: { path in
                                      guard let text = files[path] else { throw CocoaError(.fileNoSuchFile) }
                                      return text
                                  }, home: "/Users/test")
}

@Suite struct SiteEnvImportTests {
    @Test func parseMatchesReadSetting() {
        let settings = SiteEnv.parse("# comment\r\n\r\nexport A=1\r\nB=\"two words\"\nC='3'\nA=last\nD=\nnot a setting\n")
        #expect(settings == ["A": "last", "B": "two words", "C": "3", "D": ""])
    }

    @Test func importMapsEveryKey() throws {
        let (env, secrets) = try importing()
        #expect(env.name == "tcos")
        #expect(env.username == "ops")
        #expect(env.wifiSSID == "Rivendell")
        #expect(env.wifiCountry == "GB")
        #expect(env.timezone == "Europe/London")
        #expect(env.sshPublicKey == testKey)
        #expect(env.provisionMode == .agent)
        #expect(env.orgID == "org-1")
        #expect(env.locationID == "loc-1")
        #expect(env.packages == ["curl", "jq"])
        #expect(env.namePrefix == "tcos")
        #expect(secrets.wifiPassword == "mellon-friend")
        #expect(secrets.tailscaleAuthKey == "tskey-1")
        let hash = try #require(secrets.passwordHash)
        #expect(hash == SHA512Crypt.hash("hunter22", salt: String(hash.split(separator: "$")[1])))
    }

    @Test func importIgnoresApiKeys() throws {
        let (env, secrets) = try importing()
        let text = String(describing: env) + String(reflecting: secrets)
        #expect(!text.contains("key-secret") && !text.contains("key-id"))
    }

    @Test func missingKeyFileNamesPath() {
        #expect(throws: SiteEnvImportError.missingSSHKey("/Users/test/.ssh/id_ed25519.pub")) { try importing(files: [:]) }
    }

    @Test func missingPasswordIsAnError() {
        #expect(throws: SiteEnvImportError.missingPassword) {
            try importing(tcos.replacingOccurrences(of: "PASSWORD=hunter22\n", with: ""))
        }
    }

    @Test func emptyWifiIsNoWifi() throws {
        let (env, secrets) = try importing(tcos.replacingOccurrences(of: "\"Rivendell\"", with: "")
            .replacingOccurrences(of: "'mellon-friend'", with: ""))
        #expect(env.wifiSSID == nil)
        #expect(secrets.wifiPassword == nil)
    }

    @Test func noPackagesFileUsesDefaults() throws {
        #expect(try importing(packages: nil).0.packages == Environment.defaultPackages)
    }

    @Test func missingSettingsKeepDefaults() throws {
        let (env, _) = try importing("PASSWORD=pw\nSSH_PUBLIC_KEY_FILE=/keys/k.pub\n", files: ["/keys/k.pub": testKey])
        #expect(env.username == "viam")
        #expect(env.provisionMode == .full)
        #expect(env.orgID == nil)
    }

    @Test func unknownProvisionModeIsAnError() {
        #expect(throws: SiteEnvImportError.unknownProvisionMode("cloud")) {
            try importing(tcos.replacingOccurrences(of: "PROVISION_MODE=agent", with: "PROVISION_MODE=cloud"))
        }
    }

    @Test func importFileSavesAndReimportKeepsTheID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try testKey.write(to: dir.appendingPathComponent("k.pub"), atomically: true, encoding: .utf8)
        let envFile = dir.appendingPathComponent("tcos.env")
        try "PASSWORD=pw\nSSH_PUBLIC_KEY_FILE=\(dir.path)/k.pub\nWIFI_SSID=shop\n".write(to: envFile, atomically: true, encoding: .utf8)
        try "curl\n".write(to: dir.appendingPathComponent("tcos.packages.txt"), atomically: true, encoding: .utf8)
        let store = FileEnvironmentStore(file: dir.appendingPathComponent("environments.json"), vault: InMemorySecretsVault())

        let first = try SiteEnvImport.importFile(at: envFile, into: store, home: "/Users/test")
        #expect(first.name == "tcos")
        #expect(first.packages == ["curl"])
        #expect(first.hasPassword)

        try "PASSWORD=pw\nSSH_PUBLIC_KEY_FILE=\(dir.path)/k.pub\nWIFI_SSID=lab\n".write(to: envFile, atomically: true, encoding: .utf8)
        let second = try SiteEnvImport.importFile(at: envFile, into: store, home: "/Users/test")
        #expect(second.id == first.id)
        #expect(try store.all().map(\.wifiSSID) == ["lab"])
    }
}
