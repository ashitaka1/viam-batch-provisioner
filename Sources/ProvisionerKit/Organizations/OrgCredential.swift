public import Foundation
import os

/// An org API key the app holds, one per Viam organization.
public struct OrgCredential: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var orgID: String
    public var orgName: String
    public var keyID: String
    public var key: String
    public var keyName: String
    public var addedAt: Date

    public var id: String { orgID }

    public init(_ payload: PairingPayload, addedAt: Date) {
        orgID = payload.orgID
        orgName = payload.orgName
        keyID = payload.keyID
        key = payload.key
        keyName = payload.keyName
        self.addedAt = addedAt
    }

    public var description: String { "OrgCredential(org: \(orgName) \(orgID), key: \(keyName) \(keyID))" }
    public var debugDescription: String { description }
}

/// Holds one credential per org ID. Saving an org already present replaces it.
public protocol OrgCredentialStore: Sendable {
    /// Sorted by org name.
    func all() throws -> [OrgCredential]
    func save(_ credential: OrgCredential) throws
    /// Removing an org that isn't stored does nothing.
    func remove(orgID: String) throws
}

public final class InMemoryOrgCredentialStore: OrgCredentialStore {
    private let credentials = OSAllocatedUnfairLock<[String: OrgCredential]>(initialState: [:])

    public init(_ initial: [OrgCredential] = []) {
        credentials.withLock { state in for credential in initial { state[credential.orgID] = credential } }
    }

    public func all() throws -> [OrgCredential] {
        credentials.withLock { $0.values.sorted { $0.orgName < $1.orgName } }
    }

    public func save(_ credential: OrgCredential) throws {
        credentials.withLock { $0[credential.orgID] = credential }
    }

    public func remove(orgID: String) throws {
        _ = credentials.withLock { $0.removeValue(forKey: orgID) }
    }
}
