import Foundation
@testable import ProvisionerKit
import Testing

/// Viam's location list for an org, as an org key gets it.
private struct ListFleet: ViamFleet {
    var listing: Result<[ViamLocation], FleetError>
    func locations() async throws(FleetError) -> [ViamLocation] { try listing.get() }
    func machines(location: String) async throws(FleetError) -> [ViamMachine] { [] }
    func createMachine(name: String, location: String) async throws(FleetError) -> String { "" }
    func mainPart(machine: String) async throws(FleetError) -> MachinePart { throw .failed("unused") }
    func deleteMachine(id: String) async throws(FleetError) {}
}

private struct UnusedProbe: KeyProbe {
    func authenticate() async throws(KeyCheckError) { throw .rejected }
    func organizations() async throws(FleetError) -> [ViamOrganization] { [] }
    func organization(id: String) async throws(FleetError) -> ViamOrganization { throw .rejected("") }
    func locations(org: String) async throws(FleetError) -> [ViamLocation] { [] }
    func location(id: String) async throws(FleetError) -> (location: ViamLocation, orgIDs: [String]) { throw .rejected("") }
}

private let acme = ViamOrganization(id: "org-1", name: "Acme")
private let shopFloor = ViamLocation(id: "loc-shop", name: "Shop floor")
private let lab = ViamLocation(id: "loc-lab", name: "Lab")

private let orgKey = ViamAPIKey(keyID: "org-key", key: "k", scope: .organization(id: acme.id, name: acme.name), addedAt: .distantPast)
private func locationKey(_ location: ViamLocation) -> ViamAPIKey {
    ViamAPIKey(keyID: "\(location.id)-key", key: "k",
               scope: .location(id: location.id, name: location.name, orgID: acme.id, orgName: acme.name), addedAt: .distantPast)
}

/// Environments driven by real `ViamKeys` over an in-memory key store.
@MainActor
private final class KeyHarness {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("key-reach-\(UUID().uuidString).json")
    let store: FileEnvironmentStore
    let keys: ViamKeys
    lazy var model = EnvironmentsModel(
        store: store, orgs: { [keys] in keys.orgs }, fleet: { [keys] in keys.fleet(org: $0, location: $1) },
        grantedLocations: { [keys] in keys.grantedLocations(org: $0) },
        reaches: { [keys] in keys.key(org: $0, location: $1) != nil }, readFile: { _ in nil }, home: "/Users/test")

    init(_ stored: [ViamAPIKey], listing: Result<[ViamLocation], FleetError> = .success([lab, shopFloor])) {
        store = FileEnvironmentStore(file: file, vault: InMemorySecretsVault())
        keys = ViamKeys(store: InMemoryAPIKeyStore(stored), authenticate: { _, _ in "token" }, probe: { _, _ in UnusedProbe() },
                        makeFleet: { _, _ in ListFleet(listing: listing) })
        keys.load()
    }

    deinit { try? FileManager.default.removeItem(at: file) }

    /// A full-mode environment at `location`.
    func environment(_ name: String, location: String, org: String = "org-1") throws -> Environment {
        var environment = try model.create(name: name)
        environment.orgID = org
        environment.orgName = org == "org-1" ? "Acme" : org
        environment.locationID = location
        environment.locationName = location
        try model.update(environment)
        return try #require(model.environments.first { $0.id == environment.id })
    }
}

@MainActor @Suite struct KeyReachTests {
    @Test func aLocationKeyReachesOnlyItsLocation() async throws {
        let h = KeyHarness([locationKey(shopFloor)])
        let shop = try h.environment("Shop", location: "loc-shop")
        let other = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .loaded([shopFloor]))
        #expect(!h.model.isUnreachableWithKey(shop))
        #expect(h.model.isUnreachableWithKey(other))
        #expect(h.model.problems(for: other).contains(EnvironmentProblem(field: .location, message: "Not reachable with this key")))
    }

    @Test func locationKeysListTheirLocationsSortedByName() async throws {
        let h = KeyHarness([locationKey(shopFloor), locationKey(lab)])
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .loaded([lab, shopFloor]))
    }

    @Test func anOrgKeyListsTheOrgsLocationsFromViam() async throws {
        let h = KeyHarness([orgKey], listing: .success([shopFloor]))
        let gone = try h.environment("Gone", location: "loc-gone")
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .loaded([shopFloor]))
        #expect(!h.model.isUnreachableWithKey(gone))
        #expect(h.model.problems(for: gone).contains(EnvironmentProblem(field: .location, message: "\"loc-gone\" no longer exists in Acme.")))
    }

    @Test func anOrgKeysRefusedListIsRejected() async {
        let h = KeyHarness([orgKey], listing: .failure(.rejected("permission denied")))
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .rejected("permission denied"))
    }

    @Test func orgOutsideTheKeysIsUnreachableAndKeepsItsSettings() async throws {
        let h = KeyHarness([locationKey(shopFloor)])
        let other = try h.environment("Other", location: "loc-x", org: "org-2")
        #expect(h.model.isUnreachableWithKey(other))
        #expect(h.model.problems(for: other).contains(EnvironmentProblem(field: .org, message: "Not reachable with this key")))
        let stored = try #require(h.model.environments.first { $0.id == other.id })
        #expect(stored.orgID == "org-2" && stored.locationID == "loc-x")
    }

    @Test func removingTheKeyMakesTheEnvironmentAskForOne() throws {
        let h = KeyHarness([orgKey])
        let shop = try h.environment("Shop", location: "loc-shop")
        try h.keys.remove(keyID: "org-key")
        #expect(h.model.problems(for: shop).contains(EnvironmentProblem(field: .org, message: "Add a Viam API key to use Acme.")))
        #expect(!h.model.isUnreachableWithKey(shop))
    }

    @Test func forgettingLocationsClearsThem() async throws {
        let h = KeyHarness([locationKey(shopFloor)])
        await h.model.loadLocations(org: "org-1")
        h.model.forgetLocations()
        #expect(h.model.locations(org: "org-1") == .idle)
    }
}
