import Foundation
@testable import ProvisionerKit
import Testing

/// Viam as one key sees it.
private struct FakeProbe: KeyProbe {
    var listed: Result<[ViamOrganization], FleetError> = .failure(.rejected("permission denied"))
    var orgs: [String: ViamOrganization] = [:]
    var orgLocations: [String: [ViamLocation]] = [:]
    var locations: [String: (ViamLocation, [String])] = [:]
    var unreachable = false
    var refuseKey = false

    func authenticate() async throws(KeyCheckError) {
        if refuseKey { throw .rejected }
    }
    func organizations() async throws(FleetError) -> [ViamOrganization] {
        if unreachable { throw .unreachable("offline") }
        return try listed.get()
    }
    func organization(id: String) async throws(FleetError) -> ViamOrganization {
        if unreachable { throw .unreachable("offline") }
        guard let org = orgs[id] else { throw .rejected("permission denied") }
        return org
    }
    func locations(org: String) async throws(FleetError) -> [ViamLocation] {
        if unreachable { throw .unreachable("offline") }
        guard let list = orgLocations[org] else { throw .rejected("permission denied") }
        return list
    }
    func location(id: String) async throws(FleetError) -> (location: ViamLocation, orgIDs: [String]) {
        if unreachable { throw .unreachable("offline") }
        guard let found = locations[id] else { throw .failed("not found") }
        return found
    }
}

private let acme = ViamOrganization(id: "org-1", name: "Acme")
private let shop = ViamLocation(id: "loc-1", name: "Shop floor")

/// An org key: lists its org and the org's locations, and reads both.
private let orgKey = FakeProbe(listed: .success([acme]), orgs: ["org-1": acme], orgLocations: ["org-1": [shop]],
                               locations: ["loc-1": (shop, ["org-1"])])
/// A location key: reads its location and nothing else.
private let locationKey = FakeProbe(locations: ["loc-1": (shop, ["org-1"])])
/// A location key as Viam answers one: lists its org and, in it, only its own location.
private let listingLocationKey = FakeProbe(listed: .success([acme]), orgs: ["org-1": acme], orgLocations: ["org-1": [shop]],
                                           locations: ["loc-1": (shop, ["org-1"])])

@Suite struct KeyCheckTests {
    @Test func anOrgKeyIsFoundFromTheKeyAlone() async throws {
        #expect(try await KeyCheck.scope(probe: orgKey, kind: .organization, scopeID: nil) == .organization(id: "org-1", name: "Acme"))
    }

    @Test func aLocationKeyIsFoundFromTheOneLocationItLists() async throws {
        #expect(try await KeyCheck.scope(probe: listingLocationKey, kind: .location, scopeID: nil)
            == .location(id: "loc-1", name: "Shop floor", orgID: "org-1", orgName: "Acme"))
    }

    /// Viam answers an org key in a one-location org exactly as it answers that
    /// location's key, so the chosen kind is trusted.
    @Test func theChosenKindDecidesBetweenKeysViamAnswersAlike() async throws {
        #expect(try await KeyCheck.scope(probe: listingLocationKey, kind: .organization, scopeID: nil)
            == .organization(id: "org-1", name: "Acme"))
    }

    @Test func aLocationKeyListingSeveralLocationsAsksForTheScopeID() async {
        var probe = listingLocationKey
        probe.orgLocations = ["org-1": [shop, ViamLocation(id: "loc-2", name: "Dock")]]
        await #expect(throws: KeyCheckError.needsScopeID) { try await KeyCheck.scope(probe: probe, kind: .location, scopeID: nil) }
    }

    @Test func aKeyThatListsNoOrgAsksForTheScopeID() async {
        for kind in [APIKeyKind.organization, .location] {
            await #expect(throws: KeyCheckError.needsScopeID, "\(kind)") {
                try await KeyCheck.scope(probe: locationKey, kind: kind, scopeID: nil)
            }
        }
    }

    @Test func anOrgKeyListingOneOrgButNotItsLocationsAsksForTheScopeID() async {
        var probe = locationKey
        probe.listed = .success([acme])
        await #expect(throws: KeyCheckError.needsScopeID) { try await KeyCheck.scope(probe: probe, kind: .organization, scopeID: nil) }
    }

    @Test func aLocationIDGivesALocationScopeNamingItsOrg() async throws {
        var probe = locationKey
        probe.orgs = ["org-1": acme]
        #expect(try await KeyCheck.scope(probe: probe, kind: .location, scopeID: "loc-1")
            == .location(id: "loc-1", name: "Shop floor", orgID: "org-1", orgName: "Acme"))
    }

    @Test func anOrgViamWontNameIsNamedByItsID() async throws {
        #expect(try await KeyCheck.scope(probe: locationKey, kind: .location, scopeID: "loc-1")
            == .location(id: "loc-1", name: "Shop floor", orgID: "org-1", orgName: "org-1"))
    }

    @Test func anOrgIDGivesAnOrgScope() async throws {
        #expect(try await KeyCheck.scope(probe: orgKey, kind: .organization, scopeID: " org-1\n") == .organization(id: "org-1", name: "Acme"))
    }

    @Test func anIDOfTheOtherKindIsOutOfReach() async {
        await #expect(throws: KeyCheckError.outOfReach("org-1")) { try await KeyCheck.scope(probe: orgKey, kind: .location, scopeID: "org-1") }
        await #expect(throws: KeyCheckError.outOfReach("loc-1")) { try await KeyCheck.scope(probe: orgKey, kind: .organization, scopeID: "loc-1") }
    }

    @Test func anIDTheKeyDoesntReachIsRefused() async {
        await #expect(throws: KeyCheckError.outOfReach("org-2")) {
            try await KeyCheck.scope(probe: locationKey, kind: .organization, scopeID: "org-2")
        }
    }

    @Test func unreachableViamIsReportedAsSuch() async {
        var probe = orgKey
        probe.unreachable = true
        for kind in [APIKeyKind.organization, .location] {
            await #expect(throws: KeyCheckError.unreachable("offline"), "\(kind)") {
                try await KeyCheck.scope(probe: probe, kind: kind, scopeID: nil)
            }
        }
        await #expect(throws: KeyCheckError.unreachable("offline")) { try await KeyCheck.scope(probe: probe, kind: .location, scopeID: "loc-1") }
    }

    @Test func aRefusedKeyIsRejected() async {
        var probe = orgKey
        probe.refuseKey = true
        await #expect(throws: KeyCheckError.rejected) { try await KeyCheck.scope(probe: probe, kind: .organization, scopeID: nil) }
    }

    @Test func aKeyListingNoneOrSeveralOrgsAsksForTheScopeID() async {
        let beta = ViamOrganization(id: "org-2", name: "Beta")
        for listed in [[acme, beta], []] {
            var probe = orgKey
            probe.listed = .success(listed)
            await #expect(throws: KeyCheckError.needsScopeID, "listing \(listed.count) orgs") {
                try await KeyCheck.scope(probe: probe, kind: .organization, scopeID: nil)
            }
        }
    }

    @Test func anOrgNameRefusedByIDIsFoundInTheList() async throws {
        var probe = locationKey
        probe.listed = .success([acme])
        #expect(try await KeyCheck.scope(probe: probe, kind: .location, scopeID: "loc-1")
            == .location(id: "loc-1", name: "Shop floor", orgID: "org-1", orgName: "Acme"))
    }

    @Test func anOrgWhoseLocationsAreRefusedIsOutOfReach() async {
        var probe = locationKey
        probe.orgs = ["org-1": acme]
        await #expect(throws: KeyCheckError.outOfReach("org-1")) {
            try await KeyCheck.scope(probe: probe, kind: .organization, scopeID: "org-1")
        }
    }
}
