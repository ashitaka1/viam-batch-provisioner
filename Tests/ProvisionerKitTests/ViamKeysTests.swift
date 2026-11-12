import Foundation
@testable import ProvisionerKit
import Testing

private let acme = ViamOrganization(id: "org-1", name: "Acme")
private let shop = ViamLocation(id: "loc-shop", name: "Shop floor")
private let lab = ViamLocation(id: "loc-lab", name: "Lab")
private let added = Date(timeIntervalSince1970: 1_793_000_000)

/// Viam as each key ID sees it: `org-key` holds Acme, `shop-key` holds the shop
/// floor, `refused` is refused, `offline` can't reach Viam.
private struct Probe: KeyProbe {
    let keyID: String
    let key: String

    func authenticate() async throws(KeyCheckError) {
        if keyID == "refused" { throw .rejected }
        if keyID == "offline" { throw .unreachable("offline") }
    }
    func organizations() async throws(FleetError) -> [ViamOrganization] {
        guard keyID == "org-key" else { throw .rejected("permission denied") }
        return [acme]
    }
    func organization(id: String) async throws(FleetError) -> ViamOrganization {
        guard id == acme.id else { throw .rejected("permission denied") }
        return acme
    }
    func locations(org: String) async throws(FleetError) -> [ViamLocation] {
        guard keyID == "org-key", org == acme.id else { throw .rejected("permission denied") }
        return [lab, shop]
    }
    func location(id: String) async throws(FleetError) -> (location: ViamLocation, orgIDs: [String]) {
        if id == shop.id { return (shop, [acme.id]) }
        throw .failed("not found")
    }
}

/// A fleet that remembers the token provider it was made with.
private struct TokenFleet: ViamFleet {
    let orgID: String
    let tokens: any BearerTokenProvider
    func locations() async throws(FleetError) -> [ViamLocation] { [] }
    func machines(location: String) async throws(FleetError) -> [ViamMachine] { [] }
    func createMachine(name: String, location: String) async throws(FleetError) -> String { "" }
    func mainPart(machine: String) async throws(FleetError) -> MachinePart { throw .failed("unused") }
    func deleteMachine(id: String) async throws(FleetError) {}
}

@MainActor
private func model(_ store: InMemoryAPIKeyStore = InMemoryAPIKeyStore(), auth: ScriptedAuth = ScriptedAuth()) -> ViamKeys {
    let keys = ViamKeys(store: store, authenticate: auth.authenticate, probe: { Probe(keyID: $0, key: $1) },
                        makeFleet: { TokenFleet(orgID: $0, tokens: $1) }, now: { added })
    keys.load()
    return keys
}

private func orgKey(_ id: String = "org-key") -> ViamAPIKey {
    ViamAPIKey(keyID: id, key: "secret-\(id)", scope: .organization(id: acme.id, name: acme.name), addedAt: added)
}

private func locationKey(_ id: String = "shop-key", _ location: ViamLocation = shop) -> ViamAPIKey {
    ViamAPIKey(keyID: id, key: "secret-\(id)", scope: .location(id: location.id, name: location.name, orgID: acme.id, orgName: acme.name),
               addedAt: added)
}

@MainActor @Suite struct ViamKeysTests {
    @Test func noKeysIsSignedOut() {
        let keys = model()
        #expect(!keys.isSignedIn)
        #expect(keys.orgs == .signedOut)
    }

    @Test func orgsAreUnknownUntilLoaded() {
        let keys = ViamKeys(store: InMemoryAPIKeyStore([orgKey()]), authenticate: ScriptedAuth().authenticate,
                            probe: { Probe(keyID: $0, key: $1) }, makeFleet: { TokenFleet(orgID: $0, tokens: $1) })
        #expect(keys.orgs == .unknown)
    }

    @Test func addingAnOrgKeyStoresItWithItsScope() async throws {
        let store = InMemoryAPIKeyStore()
        let keys = model(store)
        try await keys.add(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil)
        #expect(try store.all().keys == [orgKey()])
        #expect(keys.isSignedIn)
        #expect(keys.orgs == .known([acme]))
    }

    @Test func addingALocationKeyWithItsLocationIDStoresTheLocationScope() async throws {
        let keys = model()
        try await keys.add(keyID: "shop-key", key: "secret-shop-key", kind: .location, scopeID: "loc-shop")
        #expect(keys.keys == [locationKey()])
        #expect(keys.keys.first?.scope.label == "Shop floor · Acme")
    }

    @Test func pastedValuesAreTrimmed() async throws {
        let keys = model()
        try await keys.add(keyID: " org-key\n", key: "\tsecret-org-key \n", kind: .organization, scopeID: "  ")
        #expect(keys.keys == [orgKey()])
    }

    @Test func aRefusedKeyStoresNothing() async throws {
        let store = InMemoryAPIKeyStore()
        let keys = model(store)
        await #expect(throws: KeyCheckError.rejected) { try await keys.add(keyID: "refused", key: "k", kind: .organization, scopeID: nil) }
        #expect(try store.all().keys.isEmpty)
        #expect(!keys.isSignedIn)
    }

    @Test func unreachableViamStoresNothing() async throws {
        let store = InMemoryAPIKeyStore()
        await #expect(throws: KeyCheckError.unreachable("offline")) {
            try await model(store).add(keyID: "offline", key: "k", kind: .organization, scopeID: nil)
        }
        #expect(try store.all().keys.isEmpty)
    }

    @Test func addingAStoredKeyIDReplacesItAndItsToken() async throws {
        let auth = ScriptedAuth()
        let store = InMemoryAPIKeyStore([ViamAPIKey(keyID: "org-key", key: "old", scope: orgKey().scope, addedAt: .distantPast)])
        let keys = model(store, auth: auth)
        let before = try #require(keys.fleet(org: acme.id, location: nil) as? TokenFleet)
        _ = try await before.tokens.token(refresh: false)
        try await keys.add(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil)
        #expect(keys.keys == [orgKey()])
        let after = try #require(keys.fleet(org: acme.id, location: nil) as? TokenFleet)
        _ = try await after.tokens.token(refresh: false)
        #expect(auth.calls.map(\.key) == ["old", "secret-org-key"])
    }

    @Test func reAddingARejectedKeyClearsTheMark() async throws {
        let auth = ScriptedAuth()
        auth.answer(.refused)
        let keys = model(InMemoryAPIKeyStore([orgKey()]), auth: auth)
        let fleet = try #require(keys.fleet(org: acme.id, location: nil) as? TokenFleet)
        _ = try? await fleet.tokens.token(refresh: false)
        #expect(await poll { keys.rejected == ["org-key"] })
        try await keys.add(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil)
        #expect(keys.rejected.isEmpty)
    }

    /// A fleet made before the key was replaced may still be refused with the old secret.
    @Test func aReplacedKeysOldSecretDoesntMarkTheNewOneRejected() async throws {
        let auth = ScriptedAuth()
        let store = InMemoryAPIKeyStore([ViamAPIKey(keyID: "org-key", key: "old", scope: orgKey().scope, addedAt: .distantPast)])
        let keys = model(store, auth: auth)
        let stale = try #require(keys.fleet(org: acme.id, location: nil) as? TokenFleet)
        try await keys.add(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil)
        auth.answer(.refused)
        // The rejection is reported before `token` returns.
        _ = try? await stale.tokens.token(refresh: false)
        #expect(keys.rejected.isEmpty)
    }

    @Test func blankPastesAreRejectedWithoutCallingViam() async {
        let keys = ViamKeys(store: InMemoryAPIKeyStore(), authenticate: ScriptedAuth().authenticate,
                            probe: { _, _ in Issue.record("Viam was called"); return Probe(keyID: "", key: "") },
                            makeFleet: { TokenFleet(orgID: $0, tokens: $1) })
        await #expect(throws: KeyCheckError.rejected) { try await keys.add(keyID: " ", key: "k", kind: .organization, scopeID: nil) }
        await #expect(throws: KeyCheckError.rejected) { try await keys.add(keyID: "org-key", key: "\n", kind: .organization, scopeID: nil) }
    }

    @Test func aKeychainThatWontSaveStoresNothing() async {
        struct Full: APIKeyStore {
            struct Refused: Error, CustomStringConvertible { var description: String { "errSecDuplicateItem" } }
            func all() throws -> APIKeyListing { APIKeyListing(keys: [], unreadable: []) }
            func save(_ key: ViamAPIKey) throws { throw Refused() }
            func remove(keyID: String) throws {}
        }
        let keys = ViamKeys(store: Full(), authenticate: ScriptedAuth().authenticate,
                            probe: { Probe(keyID: $0, key: $1) }, makeFleet: { TokenFleet(orgID: $0, tokens: $1) })
        keys.load()
        await #expect(throws: KeyCheckError.notSaved("errSecDuplicateItem")) {
            try await keys.add(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil)
        }
        #expect(keys.keys.isEmpty)
    }

    @Test func anUnreadableKeychainIsReportedAndSignedOut() {
        struct Locked: APIKeyStore {
            struct Denied: Error, CustomStringConvertible { var description: String { "denied" } }
            func all() throws -> APIKeyListing { throw Denied() }
            func save(_ key: ViamAPIKey) throws {}
            func remove(keyID: String) throws {}
        }
        let keys = ViamKeys(store: Locked(), authenticate: ScriptedAuth().authenticate,
                            probe: { Probe(keyID: $0, key: $1) }, makeFleet: { TokenFleet(orgID: $0, tokens: $1) })
        keys.load()
        #expect(keys.loadError == "Couldn't read the API keys in the Keychain: denied")
        #expect(keys.loaded)
        #expect(keys.orgs == .signedOut)
    }

    @Test func orgsAreEachOrgOnceSortedByName() {
        let zeta = ViamAPIKey(keyID: "z", key: "k", scope: .organization(id: "org-z", name: "Zeta"), addedAt: added)
        let keys = model(InMemoryAPIKeyStore([zeta, orgKey(), locationKey()]))
        #expect(keys.orgs == .known([acme, ViamOrganization(id: "org-z", name: "Zeta")]))
    }

    @Test func removingTheLastKeySignsOut() throws {
        let store = InMemoryAPIKeyStore([orgKey()])
        let keys = model(store)
        try keys.remove(keyID: "org-key")
        #expect(try store.all().keys.isEmpty)
        #expect(keys.orgs == .signedOut)
    }

    @Test func aLocationKeyIsPreferredForItsLocation() {
        let keys = model(InMemoryAPIKeyStore([orgKey(), locationKey()]))
        #expect(keys.key(org: acme.id, location: shop.id)?.keyID == "shop-key")
        #expect(keys.key(org: acme.id, location: lab.id)?.keyID == "org-key")
        #expect(keys.key(org: acme.id, location: nil)?.keyID == "org-key")
    }

    @Test func aLocationKeysFleetIsOnlyForItsLocation() {
        let keys = model(InMemoryAPIKeyStore([locationKey()]))
        #expect(keys.fleet(org: acme.id, location: shop.id) != nil)
        #expect(keys.fleet(org: acme.id, location: lab.id) == nil)
        #expect(keys.fleet(org: acme.id, location: nil) == nil)
        #expect(keys.fleet(org: "org-2", location: shop.id) == nil)
    }

    @Test func grantedLocationsAreTheLocationKeysUnlessAnOrgKeyHoldsTheOrg() {
        #expect(model(InMemoryAPIKeyStore([locationKey(), locationKey("lab-key", lab)])).grantedLocations(org: acme.id) == [lab, shop])
        #expect(model(InMemoryAPIKeyStore([orgKey(), locationKey()])).grantedLocations(org: acme.id) == nil)
    }

    @Test func theFleetUsesTheChosenKey() async throws {
        let auth = ScriptedAuth()
        let keys = model(InMemoryAPIKeyStore([orgKey(), locationKey()]), auth: auth)
        let fleet = try #require(keys.fleet(org: acme.id, location: shop.id) as? TokenFleet)
        _ = try await fleet.tokens.token(refresh: false)
        #expect(auth.calls.map(\.id) == ["shop-key"])
    }

    @Test func aKeyViamRefusesLaterIsMarkedRejectedAndKept() async throws {
        let auth = ScriptedAuth()
        auth.answer(.refused)
        let keys = model(InMemoryAPIKeyStore([orgKey()]), auth: auth)
        let fleet = try #require(keys.fleet(org: acme.id, location: nil) as? TokenFleet)
        await #expect(throws: APIKeyRefused.self) { try await fleet.tokens.token(refresh: false) }
        #expect(await poll { keys.rejected == ["org-key"] })
        #expect(keys.isSignedIn)
    }

    @Test func undecodableItemsAreReportedBesideTheOtherKeys() {
        struct Listing: APIKeyStore {
            func all() throws -> APIKeyListing { APIKeyListing(keys: [orgKey()], unreadable: ["bad-id"]) }
            func save(_ key: ViamAPIKey) throws {}
            func remove(keyID: String) throws {}
        }
        let keys = ViamKeys(store: Listing(), authenticate: ScriptedAuth().authenticate,
                            probe: { Probe(keyID: $0, key: $1) }, makeFleet: { TokenFleet(orgID: $0, tokens: $1) })
        keys.load()
        #expect(keys.keys == [orgKey()])
        #expect(keys.unreadable == ["bad-id"])
    }

    // MARK: Keys file

    @Test func importAddsNewEntriesAndSkipsStoredOnes() async throws {
        let store = InMemoryAPIKeyStore([orgKey()])
        let keys = model(store)
        await keys.importKeys([
            KeysFile.Entry(keyID: "org-key", key: "other", kind: .organization, scopeID: nil),
            KeysFile.Entry(keyID: "shop-key", key: "secret-shop-key", kind: .location, scopeID: "loc-shop"),
        ])
        #expect(try store.all().keys == [orgKey(), locationKey()])
        #expect(keys.importProblems.isEmpty)
    }

    @Test func badEntriesAreReportedByKeyIDAndTheRestLoad() async {
        let keys = model()
        await keys.importKeys([
            KeysFile.Entry(keyID: nil, key: "s3cret-a", kind: .organization, scopeID: nil),
            KeysFile.Entry(keyID: "refused-key-id", key: nil, kind: .organization, scopeID: nil),
            KeysFile.Entry(keyID: "no-scope-key", key: "s3cret-c", kind: nil, scopeID: nil),
            KeysFile.Entry(keyID: "refused", key: "s3cret-b", kind: .organization, scopeID: nil),
            KeysFile.Entry(keyID: "org-key", key: "secret-org-key", kind: .organization, scopeID: nil),
        ])
        #expect(keys.importProblems == [
            "Entry 1: missing key_id", "refused-…: missing key", "no-scope…: missing organization_id or location_id",
            "refused…: Viam rejected this key.",
        ])
        #expect(!keys.importProblems.joined().contains("s3cret"))
        #expect(keys.keys == [orgKey()])
    }

    @Test func aKeysFileLoadsItsKeys() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
        try Data(#"[{"key_id": "shop-key", "key": "secret-shop-key", "location_id": "loc-shop"}]"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let keys = model()
        await keys.importKeys(fromFile: file.path)
        #expect(keys.keys == [locationKey()])
        #expect(keys.importProblems.isEmpty)
    }

    @Test func anUnreadableFileIsReportedWithoutItsText() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
        try Data(#"{"key_id": "a", "key": "s3cret"}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let keys = model()
        await keys.importKeys(fromFile: file.path)
        #expect(keys.importProblems == ["The keys file \(file.path) couldn't be read as a JSON array of keys."])
    }
}

@Suite struct KeysFileTests {
    @Test func entriesReadEitherScopeAndToleratesMissingFields() throws {
        let data = Data(#"""
        [{"key_id": "a", "key": "ka", "location_id": "loc-1"},
         {"key_id": "b", "key": "kb", "organization_id": "org-1"},
         {"key_id": "c"}]
        """#.utf8)
        #expect(try KeysFile.entries(data) == [
            KeysFile.Entry(keyID: "a", key: "ka", kind: .location, scopeID: "loc-1"),
            KeysFile.Entry(keyID: "b", key: "kb", kind: .organization, scopeID: "org-1"),
            KeysFile.Entry(keyID: "c", key: nil, kind: nil, scopeID: nil),
        ])
    }

    @Test func entryDescriptionOmitsTheKey() {
        #expect(!String(describing: KeysFile.Entry(keyID: "a", key: "s3cret", kind: nil, scopeID: nil)).contains("s3cret"))
    }
}
