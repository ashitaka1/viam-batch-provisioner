import Foundation
@testable import ProvisionerKit
import Testing

private let added = Date(timeIntervalSince1970: 1_793_000_000)

private func orgKey(_ id: String, org: String = "Acme", secret: String = "k") -> ViamAPIKey {
    ViamAPIKey(keyID: id, key: secret, scope: .organization(id: "org-\(org)", name: org), addedAt: added)
}

private func locationKey(_ id: String, location: String, org: String = "Acme") -> ViamAPIKey {
    ViamAPIKey(keyID: id, key: "k", scope: .location(id: "loc-\(location)", name: location, orgID: "org-\(org)", orgName: org),
               addedAt: added)
}

@Test func labelNamesTheOrganizationOrTheLocation() {
    #expect(orgKey("a").scope.label == "Acme · organization")
    #expect(locationKey("b", location: "Shop floor").scope.label == "Shop floor · Acme")
}

@Test func descriptionOmitsTheKey() {
    let key = orgKey("a1", secret: "s3cret")
    #expect(!String(describing: key).contains("s3cret"))
    #expect(!String(reflecting: key).contains("s3cret"))
}

@Test func decodeSkipsAndReportsUndecodableItems() throws {
    let good = try JSONEncoder().encode(orgKey("good"))
    let listing = KeychainAPIKeyStore.decode([(account: "bad-id", data: Data("x".utf8)), (account: "good", data: good)])
    #expect(listing.keys == [orgKey("good")])
    #expect(listing.unreadable == ["bad-id"])
}

/// The behavior an `APIKeyStore` promises.
private enum Contract {
    static func saveReplacesSameKeyID(_ store: any APIKeyStore) throws {
        try store.save(orgKey("a", secret: "old"))
        try store.save(orgKey("a", secret: "new"))
        #expect(try store.all().keys.map(\.key) == ["new"])
    }

    static func listsSortedByLabel(_ store: any APIKeyStore) throws {
        try store.save(orgKey("z", org: "Beta"))
        try store.save(locationKey("y", location: "Shop floor"))
        try store.save(orgKey("x", org: "Acme"))
        #expect(try store.all().keys.map(\.keyID) == ["x", "z", "y"])
        #expect(try store.all().keys.last == locationKey("y", location: "Shop floor"), "every field survives the round trip")
    }

    static func removeDeletesOnlyThatKey(_ store: any APIKeyStore) throws {
        try store.save(orgKey("a"))
        try store.save(orgKey("b", org: "Beta"))
        try store.remove(keyID: "a")
        #expect(try store.all().keys.map(\.keyID) == ["b"])
    }

    static func removeMissingKeyIsNotAnError(_ store: any APIKeyStore) throws {
        try store.remove(keyID: "nope")
        #expect(try store.all() == APIKeyListing(keys: [], unreadable: []))
    }
}

@Suite struct InMemoryAPIKeyStoreTests {
    @Test func saveReplacesSameKeyID() throws { try Contract.saveReplacesSameKeyID(InMemoryAPIKeyStore()) }
    @Test func listsSortedByLabel() throws { try Contract.listsSortedByLabel(InMemoryAPIKeyStore()) }
    @Test func removeDeletesOnlyThatKey() throws { try Contract.removeDeletesOnlyThatKey(InMemoryAPIKeyStore()) }
    @Test func removeMissingKeyIsNotAnError() throws { try Contract.removeMissingKeyIsNotAnError(InMemoryAPIKeyStore()) }
}

/// True when this process can write the login keychain. A sandboxed or headless
/// shell gets errSecInteractionNotAllowed; the suite is then skipped, not failed.
private let keychainReachable: Bool = {
    let store = KeychainAPIKeyStore(service: "test.viam-provisioner.probe.\(UUID().uuidString)")
    defer { try? store.remove(keyID: "probe") }
    return (try? store.save(orgKey("probe"))) != nil
}()

@Suite(.enabled(if: keychainReachable, "the login keychain is not reachable from this process"))
struct KeychainAPIKeyStoreTests {
    let store = KeychainAPIKeyStore(service: "test.viam-provisioner.\(UUID().uuidString)")

    private func run(_ body: (any APIKeyStore) throws -> Void) throws {
        defer { for key in (try? store.all().keys) ?? [] { try? store.remove(keyID: key.keyID) } }
        try body(store)
    }

    @Test func saveReplacesSameKeyID() throws { try run(Contract.saveReplacesSameKeyID) }
    @Test func listsSortedByLabel() throws { try run(Contract.listsSortedByLabel) }
    @Test func removeDeletesOnlyThatKey() throws { try run(Contract.removeDeletesOnlyThatKey) }
    @Test func removeMissingKeyIsNotAnError() throws { try run(Contract.removeMissingKeyIsNotAnError) }
}

@Test func orgCredentialDescriptionOmitsKey() {
    let credential = OrgCredential(HandoffPayload(orgID: "o1", orgName: "Acme", keyID: "id-o1", key: "s3cret", keyName: "provisioner-app"),
                                   addedAt: added)
    #expect(!String(describing: credential).contains("s3cret"))
}
