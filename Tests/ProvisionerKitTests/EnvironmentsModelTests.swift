import Foundation
@testable import ProvisionerKit
import Testing

private func credential(_ orgID: String, name: String) -> OrgCredential {
    OrgCredential(PairingPayload(orgID: orgID, orgName: name, keyID: "id-\(orgID)", key: "k", keyName: "provisioner-app studio"),
                  addedAt: Date(timeIntervalSince1970: 1_793_000_000))
}

private struct ThrowingStore: EnvironmentStore {
    struct Broken: Error {}
    func all() throws -> [Environment] { throw EnvironmentStoreError.unreadable(path: "/tmp/environments.json", reason: "bad") }
    func secrets(id: UUID) throws -> EnvironmentSecrets { throw Broken() }
    func save(_ environment: Environment, secrets: EnvironmentSecrets?) throws { throw Broken() }
    func remove(id: UUID) throws { throw Broken() }
}

@MainActor
private final class Harness {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("env-model-\(UUID().uuidString).json")
    let store: FileEnvironmentStore
    let fleet = FakeFleet()
    var rows: [OrganizationsModel.Row] = [OrganizationsModel.Row(credential: credential("org-1", name: "Acme"), status: .unchecked)]
    var files: [String: String] = [:]
    lazy var model = EnvironmentsModel(
        store: store, orgs: { [unowned self] in rows }, fleet: { [fleet] _ in fleet },
        readFile: { [unowned self] path in files[path] }, home: "/Users/test")

    init() { store = FileEnvironmentStore(file: file, vault: InMemorySecretsVault()) }
    deinit { try? FileManager.default.removeItem(at: file) }

    func stored(_ id: UUID) throws -> Environment { try #require(try store.all().first { $0.id == id }) }
}

@MainActor @Suite struct EnvironmentsModelTests {
    @Test func createPicksUnusedNameAndSelectsTheOnlyOrg() throws {
        let h = Harness()
        let first = try h.model.create()
        let second = try h.model.create()
        #expect([first.name, second.name] == ["New Environment", "New Environment 2"])
        #expect(first.orgID == "org-1" && first.orgName == "Acme")
        let storedIDs = Set(try h.store.all().map(\.id))
        #expect(storedIDs == [first.id, second.id])
        #expect(h.model.environments.map(\.name) == ["New Environment", "New Environment 2"])
    }

    @Test func createLeavesOrgEmptyWhenSeveralArePaired() throws {
        let h = Harness()
        h.rows.append(OrganizationsModel.Row(credential: credential("org-2", name: "Beta"), status: .unchecked))
        #expect(try h.model.create().orgID == nil)
    }

    @Test func createUsesTheDefaultSSHKeyWhenItParses() throws {
        let h = Harness()
        h.files["/Users/test/.ssh/id_ed25519.pub"] = testKey + "\n"
        #expect(try h.model.create().sshPublicKey == testKey)
        h.files["/Users/test/.ssh/id_ed25519.pub"] = "garbage"
        #expect(try h.model.create().sshPublicKey == "")
    }

    @Test func duplicateCopiesSettingsAndSecretsUnderNewID() throws {
        let h = Harness()
        var shop = try h.model.create(name: "Shop")
        shop.wifiSSID = "shop"
        try h.model.update(shop)
        try h.model.setPassword("hunter22", id: shop.id)
        try h.model.setSecret(.wifiPassword, "wifipass1", id: shop.id)
        let copy = try h.model.duplicate(id: shop.id)
        #expect(copy.id != shop.id)
        #expect(copy.name == "Shop copy")
        #expect(copy.wifiSSID == "shop")
        #expect(try h.store.secrets(id: copy.id) == h.store.secrets(id: shop.id))
        #expect(try h.stored(copy.id).hasPassword)
        #expect(try h.model.duplicate(id: shop.id).name == "Shop copy 2")
    }

    @Test func renameRefusesEmptyOrDuplicateName() throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        _ = try h.model.create(name: "Lab")
        #expect(throws: EnvironmentError.self) { try h.model.rename(id: shop.id, to: "lab") }
        #expect(throws: EnvironmentError.self) { try h.model.rename(id: shop.id, to: "  ") }
        try h.model.rename(id: shop.id, to: " Shop floor ")
        #expect(try h.stored(shop.id).name == "Shop floor")
        try h.model.rename(id: shop.id, to: "shop FLOOR")
        #expect(try h.stored(shop.id).name == "shop FLOOR", "its own name in another case is not a duplicate")
    }

    @Test func updateSavesInvalidEnvironment() throws {
        let h = Harness()
        var shop = try h.model.create(name: "Shop")
        shop.namePrefix = "bad_prefix"
        try h.model.update(shop)
        #expect(try h.stored(shop.id).namePrefix == "bad_prefix")
    }

    @Test func deleteRemovesEnvironmentAndSecrets() throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        try h.model.setSecret(.wifiPassword, "wifipass1", id: shop.id)
        try h.model.delete(id: shop.id)
        #expect(h.model.environments.isEmpty)
        #expect(try h.store.all().isEmpty)
        #expect(try h.store.secrets(id: shop.id) == EnvironmentSecrets())
    }

    @Test func passwordIsStoredOnlyAsHash() throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        try h.model.setPassword("hunter22", id: shop.id)
        let hash = try #require(try h.store.secrets(id: shop.id).passwordHash)
        let salt = String(hash.split(separator: "$")[1])
        #expect(hash == SHA512Crypt.hash("hunter22", salt: salt))
        #expect(h.model.environments.first?.hasPassword == true)
        try h.model.setPassword(nil, id: shop.id)
        #expect(try h.store.secrets(id: shop.id).passwordHash == nil)
        #expect(h.model.environments.first?.hasPassword == false)
    }

    @Test(arguments: [EnvironmentField.wifiPassword, .tailscaleAuthKey])
    func secretsSetRevealAndClear(_ field: EnvironmentField) throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        try h.model.setSecret(field, "secret-1", id: shop.id)
        #expect(try h.model.revealSecret(field, id: shop.id) == "secret-1")
        let flag = { (env: Environment?) in field == .wifiPassword ? env?.hasWifiPassword : env?.hasTailscaleKey }
        #expect(flag(h.model.environments.first) == true)
        try h.model.setSecret(field, "", id: shop.id)
        #expect(try h.model.revealSecret(field, id: shop.id) == nil)
        #expect(flag(h.model.environments.first) == false)
    }

    @Test func settingOneSecretKeepsTheOthers() throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        try h.model.setPassword("hunter22", id: shop.id)
        try h.model.setSecret(.wifiPassword, "wifipass1", id: shop.id)
        try h.model.setSecret(.tailscaleAuthKey, "tskey-1", id: shop.id)
        let secrets = try h.store.secrets(id: shop.id)
        #expect(secrets.passwordHash != nil && secrets.wifiPassword == "wifipass1" && secrets.tailscaleAuthKey == "tskey-1")
    }

    @Test func shortWifiPasswordIsAProblemAfterItIsSet() throws {
        let h = Harness()
        var shop = try h.model.create(name: "Shop")
        shop.wifiSSID = "shop"
        try h.model.update(shop)
        try h.model.setSecret(.wifiPassword, "short", id: shop.id)
        let env = try #require(h.model.environments.first)
        #expect(h.model.problems(for: env).contains(EnvironmentProblem(field: .wifiPassword, message: "WiFi passwords are 8 to 63 characters.")))
    }

    @Test func problemsIncludeOrgHealth() async throws {
        let h = Harness()
        var shop = try h.model.create(name: "Shop")
        shop.locationID = "gone"
        shop.locationName = "Lab B"
        try h.model.update(shop)

        await h.fleet.setLocations(.success([ViamLocation(id: "loc-1", name: "Bench")]))
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.problems(for: shop).contains(EnvironmentProblem(field: .location, message: "\"Lab B\" no longer exists in Acme.")))

        h.rows[0].status = .rejected("bad key")
        #expect(h.model.problems(for: shop).contains(EnvironmentProblem(field: .org, message: "Viam rejected this Mac's key for Acme.")))

        h.rows = []
        #expect(h.model.problems(for: shop).contains(EnvironmentProblem(field: .org, message: "This Mac has no key for Acme.")))
        #expect(!h.model.orgIsPaired(shop))
        #expect(h.model.locations(org: "org-1") == .unpaired)
    }

    @Test func orgHealthIgnoredOutsideFullMode() throws {
        let h = Harness()
        var bench = try h.model.create(name: "Bench", mode: .osOnly)
        bench.orgID = "org-9"
        bench.orgName = "Gone"
        try h.model.update(bench)
        #expect(!h.model.problems(for: bench).contains { $0.field == .org })
    }

    @Test func locationsLoadOncePerOrgUntilReloaded() async throws {
        let h = Harness()
        #expect(h.model.locations(org: "org-1") == .idle)
        await h.model.loadLocations(org: "org-1")
        await h.model.loadLocations(org: "org-1")
        #expect(await h.fleet.locationsCalls == 1)
        #expect(h.model.locations(org: "org-1") == .loaded([ViamLocation(id: "loc-1", name: "Bench")]))
        await h.model.reloadLocations(org: "org-1")
        #expect(await h.fleet.locationsCalls == 2)
    }

    @Test func rejectedKeyShowsRejected() async throws {
        let h = Harness()
        await h.fleet.setLocations(.failure(.rejected("unauthenticated")))
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .rejected("unauthenticated"))
    }

    @Test func unreachableAndFailedShowUnreachable() async throws {
        let h = Harness()
        await h.fleet.setLocations(.failure(.unreachable("offline")))
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .unreachable("offline"))
        await h.fleet.setLocations(.failure(.failed("internal")))
        await h.model.reloadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .unreachable("internal"))
    }

    @Test func unpairedOrgDoesNotCallViam() async throws {
        let h = Harness()
        h.rows = []
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .unpaired)
        #expect(await h.fleet.locationsCalls == 0)
    }

    @Test func usageListsFullModeEnvironmentsOfTheOrg() throws {
        let h = Harness()
        let shop = try h.model.create(name: "Shop")
        _ = try h.model.create(name: "Bench", mode: .osOnly)
        #expect(h.model.usage(orgID: "org-1").map(\.id) == [shop.id])
    }

    @Test func loadReadsStoredEnvironments() throws {
        let h = Harness()
        _ = try h.model.create(name: "Shop")
        let again = EnvironmentsModel(store: h.store, orgs: { [] }, fleet: { _ in FakeFleet() })
        again.load()
        #expect(again.environments.map(\.name) == ["Shop"])
        #expect(again.loadError == nil)
    }

    @Test func loadErrorReported() {
        let model = EnvironmentsModel(store: ThrowingStore(), orgs: { [] }, fleet: { _ in FakeFleet() })
        model.load()
        #expect(model.environments.isEmpty)
        #expect(model.loadError == "Couldn't read the environments in /tmp/environments.json: bad")
    }
}
