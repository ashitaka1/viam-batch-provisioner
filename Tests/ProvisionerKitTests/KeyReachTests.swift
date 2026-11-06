import Foundation
@testable import ProvisionerKit
import Testing

/// A fleet for a key Viam won't list locations for, as a location key may be:
/// `GetLocation` answers for the granted locations and refuses the rest.
private struct GrantFleet: ViamFleet {
    var listing: Result<[ViamLocation], FleetError> = .failure(.rejected("permission denied"))
    var granted: [String: ViamLocation] = [:]
    var unreachable: Set<String> = []

    func locations() async throws(FleetError) -> [ViamLocation] { try listing.get() }
    func location(id: String) async throws(FleetError) -> ViamLocation {
        if unreachable.contains(id) { throw .unreachable("offline") }
        guard let location = granted[id] else { throw .rejected("permission denied") }
        return location
    }
    func machines(location: String) async throws(FleetError) -> [ViamMachine] { [] }
    func createMachine(name: String, location: String) async throws(FleetError) -> String { "" }
    func mainPart(machine: String) async throws(FleetError) -> MachinePart { throw .failed("unused") }
    func deleteMachine(id: String) async throws(FleetError) {}
}

private let acme = ViamOrganization(id: "org-1", name: "Acme")
private let shopFloor = ViamLocation(id: "loc-shop", name: "Shop floor")

@MainActor
private final class KeyHarness {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("key-reach-\(UUID().uuidString).json")
    let store: FileEnvironmentStore
    var fleet: GrantFleet
    var orgs: AccountOrgs = .known([acme])
    var keyLogin = true
    var defaultLocation: String?
    lazy var model = EnvironmentsModel(
        store: store, orgs: { [unowned self] in orgs }, fleet: { [fleet] _ in fleet },
        readFile: { _ in nil }, home: "/Users/test",
        keyLogin: { [unowned self] in keyLogin }, defaultLocation: { [unowned self] in defaultLocation })

    init(fleet: GrantFleet = GrantFleet(granted: ["loc-shop": shopFloor])) {
        self.fleet = fleet
        store = FileEnvironmentStore(file: file, vault: InMemorySecretsVault())
    }

    deinit { try? FileManager.default.removeItem(at: file) }

    /// A full-mode environment in Acme at `location`.
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
    @Test func refusedListReadsTheEnvironmentsLocationsOneByOne() async throws {
        let h = KeyHarness()
        let shop = try h.environment("Shop", location: "loc-shop")
        let lab = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .loaded([shopFloor]))
        #expect(h.model.locationsAreGrantsOnly(org: "org-1"))
        #expect(!h.model.isUnreachableWithKey(shop))
        #expect(h.model.isUnreachableWithKey(lab))
        #expect(h.model.problems(for: lab).contains(EnvironmentProblem(field: .location, message: EnvironmentsModel.notReachable)))
    }

    @Test func theCLIsDefaultLocationIsReadToo() async throws {
        let h = KeyHarness()
        h.defaultLocation = "loc-shop"
        let lab = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .loaded([shopFloor]))
        #expect(h.model.isUnreachableWithKey(lab))
    }

    /// A location Viam couldn't answer for may be granted, so nothing is marked.
    @Test func unansweredCandidateLeavesTheGrantUnknown() async throws {
        let h = KeyHarness(fleet: GrantFleet(granted: ["loc-shop": shopFloor], unreachable: ["loc-lab"]))
        _ = try h.environment("Shop", location: "loc-shop")
        let lab = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .unreachable("offline"))
        #expect(!h.model.isUnreachableWithKey(lab))
    }

    @Test func refusedListWithNoCandidatesStaysRejected() async {
        let h = KeyHarness()
        await h.model.loadLocations(org: "org-1")
        #expect(h.model.locations(org: "org-1") == .rejected("permission denied"))
    }

    @Test func listedLocationsAreNotGrantsOnly() async throws {
        let h = KeyHarness(fleet: GrantFleet(listing: .success([shopFloor])))
        let lab = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(!h.model.locationsAreGrantsOnly(org: "org-1"))
        #expect(h.model.isUnreachableWithKey(lab))
    }

    @Test func orgOutsideTheKeysGrantIsUnreachableAndKeepsItsSettings() async throws {
        let h = KeyHarness()
        let other = try h.environment("Other", location: "loc-x", org: "org-2")
        #expect(h.model.isUnreachableWithKey(other))
        #expect(h.model.problems(for: other).contains(EnvironmentProblem(field: .org, message: EnvironmentsModel.notReachable)))
        let stored = try #require(h.model.environments.first { $0.id == other.id })
        #expect(stored.orgID == "org-2" && stored.locationID == "loc-x")
    }

    /// A user login keeps its own wording; reach is a key's notion.
    @Test func userLoginIsNeverUnreachableWithKey() async throws {
        let h = KeyHarness()
        h.keyLogin = false
        let lab = try h.environment("Lab", location: "loc-lab")
        await h.model.loadLocations(org: "org-1")
        #expect(!h.model.isUnreachableWithKey(lab))
        #expect(h.model.problems(for: lab).contains(EnvironmentProblem(field: .location, message: "\"loc-lab\" no longer exists in Acme.")))
    }

    @Test func loadLocationsInUseLoadsEachOrgOnce() async throws {
        let h = KeyHarness()
        _ = try h.environment("Shop", location: "loc-shop")
        _ = try h.environment("Lab", location: "loc-lab")
        #expect(h.model.orgIDsInUse == ["org-1"])
        await h.model.loadLocationsInUse()
        #expect(h.model.locations(org: "org-1") == .loaded([shopFloor]))
    }
}

@Suite struct KeyScopeTests {
    private let beta = ViamOrganization(id: "org-2", name: "Beta")
    private let lab = ViamLocation(id: "loc-lab", name: "Lab")

    @Test func noOrganizationsHasNoScope() {
        #expect(KeyScope(organizations: [], locations: nil, grantsOnly: false) == nil)
    }

    @Test func severalOrganizationsAreCounted() {
        let scope = KeyScope(organizations: [acme, beta], locations: nil, grantsOnly: false)
        #expect(scope?.description == "2 organizations")
    }

    @Test func listedLocationsMeanTheOrganization() {
        let scope = KeyScope(organizations: [acme], locations: [shopFloor], grantsOnly: false)
        #expect(scope?.description == "organization Acme")
    }

    @Test func oneGrantedLocationIsTheLocation() {
        let scope = KeyScope(organizations: [acme], locations: [shopFloor], grantsOnly: true)
        #expect(scope?.description == "location Shop floor")
    }

    @Test func severalGrantedLocationsAreCounted() {
        let scope = KeyScope(organizations: [acme], locations: [lab, shopFloor], grantsOnly: true)
        #expect(scope?.description == "2 locations in Acme")
    }
}
