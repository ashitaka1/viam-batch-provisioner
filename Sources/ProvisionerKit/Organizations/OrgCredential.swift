public import Foundation

/// An org API key the app holds, one per Viam organization.
public struct OrgCredential: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var orgID: String
    public var orgName: String
    public var keyID: String
    public var key: String
    public var keyName: String
    public var addedAt: Date

    public var id: String { orgID }

    public init(_ payload: HandoffPayload, addedAt: Date) {
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
