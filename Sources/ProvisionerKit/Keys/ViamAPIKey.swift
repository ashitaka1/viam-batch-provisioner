public import Foundation

/// What a Viam API key is granted: an organization, or one location in it.
public struct APIKeyScope: Codable, Sendable, Equatable {
    public var orgID: String
    public var orgName: String
    /// Nil for an organization key.
    public var locationID: String?
    public var locationName: String?

    public static func organization(id: String, name: String) -> APIKeyScope {
        APIKeyScope(orgID: id, orgName: name, locationID: nil, locationName: nil)
    }

    public static func location(id: String, name: String, orgID: String, orgName: String) -> APIKeyScope {
        APIKeyScope(orgID: orgID, orgName: orgName, locationID: id, locationName: name)
    }

    public var isLocation: Bool { locationID != nil }

    /// `Acme · organization`, or `Shop floor · Acme`.
    public var label: String {
        if let locationID { "\(locationName ?? locationID) · \(orgName)" } else { "\(orgName) · organization" }
    }
}

/// A Viam API key the app holds, with the scope worked out when it was added.
public struct ViamAPIKey: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var keyID: String
    public var key: String
    public var scope: APIKeyScope
    public var addedAt: Date

    public init(keyID: String, key: String, scope: APIKeyScope, addedAt: Date) {
        self.keyID = keyID
        self.key = key
        self.scope = scope
        self.addedAt = addedAt
    }

    public var id: String { keyID }

    /// The key ID's first 8 characters.
    public var shortID: String { Self.shortID(keyID) }

    public static func shortID(_ keyID: String) -> String { "\(keyID.prefix(8))…" }

    public var description: String { "ViamAPIKey(\(keyID), \(scope.label))" }
    public var debugDescription: String { description }
}

/// The stored keys, and the key IDs of items that couldn't be decoded.
public struct APIKeyListing: Sendable, Equatable {
    public var keys: [ViamAPIKey]
    public var unreadable: [String]

    public init(keys: [ViamAPIKey], unreadable: [String]) {
        self.keys = keys
        self.unreadable = unreadable
    }
}

/// Holds API keys by key ID. Saving a key ID already present replaces it.
public protocol APIKeyStore: Sendable {
    /// Sorted by scope label, ignoring case, then key ID.
    func all() throws -> APIKeyListing
    func save(_ key: ViamAPIKey) throws
    /// Removing a key ID that isn't stored does nothing.
    func remove(keyID: String) throws
}

extension Array where Element == ViamAPIKey {
    func sortedByLabel() -> [ViamAPIKey] {
        sorted {
            switch $0.scope.label.localizedCaseInsensitiveCompare($1.scope.label) {
            case .orderedSame: $0.keyID < $1.keyID
            case let order: order == .orderedAscending
            }
        }
    }
}

/// Keys in memory, for tests and previews.
public final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var keys: [String: ViamAPIKey] = [:]
    private let lock = NSLock()

    public init(_ keys: [ViamAPIKey] = []) {
        for key in keys { self.keys[key.keyID] = key }
    }

    public func all() throws -> APIKeyListing {
        lock.withLock { APIKeyListing(keys: Array(keys.values).sortedByLabel(), unreadable: []) }
    }

    public func save(_ key: ViamAPIKey) throws {
        lock.withLock { keys[key.keyID] = key }
    }

    public func remove(keyID: String) throws {
        _ = lock.withLock { keys.removeValue(forKey: keyID) }
    }
}
