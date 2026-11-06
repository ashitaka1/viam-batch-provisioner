import Foundation
@testable import ProvisionerKit
import Testing

private func cred(_ orgID: String, name: String = "Acme", key: String = "k") -> OrgCredential {
    OrgCredential(PairingPayload(orgID: orgID, orgName: name, keyID: "id-\(orgID)", key: key, keyName: "provisioner-app studio 2026-10-31"),
                  addedAt: Date(timeIntervalSince1970: 1_793_000_000))
}

/// The behavior an `OrgCredentialStore` promises.
private enum Contract {
    static func saveReplacesSameOrg(_ store: any OrgCredentialStore) throws {
        try store.save(cred("o1", key: "old"))
        try store.save(cred("o1", key: "new"))
        #expect(try store.all().map(\.key) == ["new"])
    }

    static func holdsSeveralOrgsSortedByName(_ store: any OrgCredentialStore) throws {
        try store.save(cred("o2", name: "Beta"))
        try store.save(cred("o1", name: "Acme"))
        #expect(try store.all().map(\.orgName) == ["Acme", "Beta"])
        #expect(try store.all().first == cred("o1", name: "Acme"), "every field survives the round trip")
    }

    static func removeDeletesOnlyThatOrg(_ store: any OrgCredentialStore) throws {
        try store.save(cred("o1", name: "Acme"))
        try store.save(cred("o2", name: "Beta"))
        try store.remove(orgID: "o1")
        #expect(try store.all().map(\.orgID) == ["o2"])
    }

    static func removeMissingOrgIsNotAnError(_ store: any OrgCredentialStore) throws {
        try store.remove(orgID: "nope")
        #expect(try store.all().isEmpty)
    }
}

/// True when this process can write the login keychain. A sandboxed or headless
/// shell gets errSecInteractionNotAllowed; the suite is then skipped, not failed.
private let keychainReachable: Bool = {
    let store = KeychainOrgCredentialStore(service: "test.viam-provisioner.probe.\(UUID().uuidString)")
    defer { try? store.remove(orgID: "probe") }
    return (try? store.save(cred("probe"))) != nil
}()

@Suite(.enabled(if: keychainReachable, "the login keychain is not reachable from this process"))
struct KeychainOrgCredentialStoreTests {
    let store = KeychainOrgCredentialStore(service: "test.viam-provisioner.\(UUID().uuidString)")

    private func run(_ body: (any OrgCredentialStore) throws -> Void) throws {
        defer { for credential in (try? store.all()) ?? [] { try? store.remove(orgID: credential.orgID) } }
        try body(store)
    }

    @Test func saveReplacesSameOrg() throws { try run(Contract.saveReplacesSameOrg) }
    @Test func holdsSeveralOrgsSortedByName() throws { try run(Contract.holdsSeveralOrgsSortedByName) }
    @Test func removeDeletesOnlyThatOrg() throws { try run(Contract.removeDeletesOnlyThatOrg) }
    @Test func removeMissingOrgIsNotAnError() throws { try run(Contract.removeMissingOrgIsNotAnError) }
}

@Test func credentialDescriptionOmitsKey() {
    #expect(!String(describing: cred("o1", key: "s3cret")).contains("s3cret"))
}
