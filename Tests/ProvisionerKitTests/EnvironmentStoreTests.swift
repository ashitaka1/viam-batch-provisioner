import Foundation
@testable import ProvisionerKit
import Testing

private func env(_ name: String, id: UUID = UUID()) -> Environment {
    var env = Environment.new(name: name, id: id)
    env.orgID = "org-1"
    env.orgName = "Acme"
    env.locationID = "loc-1"
    env.locationName = "Lab"
    env.sshPublicKey = testKey
    env.wifiSSID = "shop"
    env.packages = ["curl"]
    return env
}

private let fullSecrets = EnvironmentSecrets(passwordHash: "$6$salt$hashvalue", wifiPassword: "wifipass1", tailscaleAuthKey: "tskey-1")

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("env-store-\(UUID().uuidString)/nested/environments.json")
}

/// The file store with an in-memory vault: the JSON file's behavior, no Keychain.
@Suite struct FileEnvironmentStoreTests {
    let file = temporaryFile()
    let store: FileEnvironmentStore

    init() { store = FileEnvironmentStore(file: file, vault: InMemorySecretsVault()) }

    private func run(_ body: (any EnvironmentStore) throws -> Void) throws {
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        try body(store)
    }

    @Test func saveThenReadRoundTripsEveryField() throws {
        try run { store in
            var shop = env("Shop")
            shop.hasPassword = true
            shop.hasWifiPassword = true
            shop.hasTailscaleKey = true
            try store.save(shop, secrets: fullSecrets)
            #expect(try store.all() == [shop])
            #expect(try store.secrets(id: shop.id) == fullSecrets)
        }
    }

    @Test func saveSetsFlagsFromSecrets() throws {
        try run { store in
            var shop = env("Shop")
            shop.hasPassword = true
            try store.save(shop, secrets: EnvironmentSecrets(wifiPassword: "wifipass1"))
            let stored = try #require(try store.all().first)
            #expect(!stored.hasPassword && stored.hasWifiPassword && !stored.hasTailscaleKey)
        }
    }

    @Test func saveReplacesSameID() throws {
        try run { store in
            let id = UUID()
            try store.save(env("Old", id: id), secrets: nil)
            try store.save(env("New", id: id), secrets: nil)
            #expect(try store.all().map(\.name) == ["New"])
        }
    }

    @Test func sortedByNameCaseInsensitive() throws {
        try run { store in
            for name in ["beta", "Alpha", "Gamma"] { try store.save(env(name), secrets: nil) }
            #expect(try store.all().map(\.name) == ["Alpha", "beta", "Gamma"])
        }
    }

    @Test func nilSecretsKeepsStoredSecrets() throws {
        try run { store in
            var shop = env("Shop")
            try store.save(shop, secrets: fullSecrets)
            shop.name = "Shop floor"
            shop.hasPassword = false
            try store.save(shop, secrets: nil)
            #expect(try store.secrets(id: shop.id) == fullSecrets)
            #expect(try store.all().first?.hasPassword == true, "flags follow the stored secrets")
        }
    }

    @Test func removeDeletesEnvironmentAndSecrets() throws {
        try run { store in
            let shop = env("Shop")
            let lab = env("Lab")
            try store.save(shop, secrets: fullSecrets)
            try store.save(lab, secrets: nil)
            try store.remove(id: shop.id)
            #expect(try store.all().map(\.id) == [lab.id])
            #expect(try store.secrets(id: shop.id) == EnvironmentSecrets())
        }
    }

    @Test func removeMissingIsNotAnError() throws {
        try run { store in
            try store.remove(id: UUID())
            #expect(try store.all().isEmpty)
        }
    }

    @Test func savingSettingsDoesNotReadTheVault() throws {
        let vault = InMemorySecretsVault()
        let store = FileEnvironmentStore(file: file, vault: vault)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        var shop = env("Shop")
        try store.save(shop, secrets: fullSecrets)
        vault.failing = true
        shop.namePrefix = "lab"
        try store.save(shop, secrets: nil)
        let stored = try #require(try store.all().first)
        #expect(stored.namePrefix == "lab")
        #expect(stored.hasPassword && stored.hasWifiPassword && stored.hasTailscaleKey, "flags kept from the file")
    }

    @Test func failedSecretDeleteKeepsTheEnvironment() throws {
        let vault = InMemorySecretsVault()
        let store = FileEnvironmentStore(file: file, vault: vault)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let shop = env("Shop")
        try store.save(shop, secrets: fullSecrets)
        vault.failing = true
        #expect(throws: (any Error).self) { try store.remove(id: shop.id) }
        #expect(try store.all().map(\.id) == [shop.id], "still listed, so the delete can be retried")
    }

    @Test func fileHoldsNoSecrets() throws {
        try run { store in
            try store.save(env("Shop"), secrets: fullSecrets)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("Shop"))
            #expect(!text.contains("wifipass1") && !text.contains("hashvalue") && !text.contains("tskey-1"))
        }
    }

    @Test func unknownFieldsInFileAreIgnored() throws {
        try run { store in
            try store.save(env("Shop"), secrets: nil)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
            json[0]["addedInAFutureVersion"] = 42
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            #expect(try store.all().map(\.name) == ["Shop"])
        }
    }

    @Test func missingFileIsEmpty() throws {
        try run { store throws in #expect(try store.all().isEmpty) }
    }

    @Test func corruptFileThrowsNamingTheFile() throws {
        try run { store in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: file)
            let error = #expect(throws: EnvironmentStoreError.self) { try store.all() }
            #expect(error?.localizedDescription.contains(file.path) == true)
        }
    }
}

/// True when this process can write the login keychain; the suite is skipped otherwise.
private let keychainReachable: Bool = {
    let vault = KeychainSecretsVault(service: "test.viam-provisioner.env-probe.\(UUID().uuidString)")
    let id = UUID()
    defer { try? vault.delete(id: id) }
    return (try? vault.write(EnvironmentSecrets(wifiPassword: "x"), id: id, label: "probe")) != nil
}()

@Suite(.enabled(if: keychainReachable, "the login keychain is not reachable from this process"))
struct KeychainSecretsVaultTests {
    let vault = KeychainSecretsVault(service: "test.viam-provisioner.env.\(UUID().uuidString)")

    @Test func writeReadReplaceDelete() throws {
        let id = UUID()
        defer { try? vault.delete(id: id) }
        #expect(try vault.read(id: id) == nil)
        try vault.write(fullSecrets, id: id, label: "test")
        #expect(try vault.read(id: id) == fullSecrets)
        try vault.write(EnvironmentSecrets(wifiPassword: "other123"), id: id, label: "test")
        #expect(try vault.read(id: id) == EnvironmentSecrets(wifiPassword: "other123"))
        try vault.delete(id: id)
        #expect(try vault.read(id: id) == nil)
        try vault.delete(id: id)
    }
}
