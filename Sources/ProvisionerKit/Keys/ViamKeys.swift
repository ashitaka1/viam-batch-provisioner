public import Foundation
public import Observation
import os

/// The Viam API keys the app holds, and what they reach (decision 49). Signed
/// in means at least one stored key.
@MainActor @Observable
public final class ViamKeys {
    private static let log = Logger(subsystem: "ProvisionerKit", category: "ViamKeys")

    /// Sorted by scope label.
    public private(set) var keys: [ViamAPIKey] = []
    /// Key IDs of Keychain items that couldn't be decoded.
    public private(set) var unreadable: [String] = []
    public private(set) var loadError: String?
    public private(set) var loaded = false
    /// Stored keys Viam has since refused.
    public private(set) var rejected: Set<String> = []
    /// What went wrong loading the QA keys file, one line per entry.
    public private(set) var importProblems: [String] = []

    public typealias MakeProbe = @Sendable (_ keyID: String, _ key: String) -> any KeyProbe
    public typealias MakeFleet = @Sendable (_ orgID: String, _ tokens: any BearerTokenProvider) -> any ViamFleet

    private let store: any APIKeyStore
    private let authenticate: APIKeyTokenSource.Authenticate
    private let probe: MakeProbe
    private let makeFleet: MakeFleet
    private let now: @Sendable () -> Date
    @ObservationIgnored private var tokenSources: [String: APIKeyTokenSource] = [:]

    public init(store: any APIKeyStore, authenticate: @escaping APIKeyTokenSource.Authenticate,
                probe: @escaping MakeProbe, makeFleet: @escaping MakeFleet, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.authenticate = authenticate
        self.probe = probe
        self.makeFleet = makeFleet
        self.now = now
    }

    public var isSignedIn: Bool { !keys.isEmpty }

    /// The organizations the keys reach, sorted by name.
    public var orgs: AccountOrgs {
        guard loaded else { return .unknown }
        guard isSignedIn else { return .signedOut }
        var seen = Set<String>()
        return .known(keys.filter { seen.insert($0.scope.orgID).inserted }
            .map { ViamOrganization(id: $0.scope.orgID, name: $0.scope.orgName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    public func load() {
        do {
            let listing = try store.all()
            keys = listing.keys
            unreadable = listing.unreadable
            loadError = nil
        } catch {
            keys = []
            unreadable = []
            loadError = "Couldn't read the API keys in the Keychain: \(error)"
        }
        let ids = Set(keys.map(\.keyID))
        tokenSources = tokenSources.filter { ids.contains($0.key) }
        rejected.formIntersection(ids)
        loaded = true
    }

    /// Checks the key with Viam and works out its scope, then stores it,
    /// replacing a stored key with the same ID. Nothing is stored on failure.
    @discardableResult
    public func add(keyID: String, key: String, kind: APIKeyKind, scopeID: String?) async throws(KeyCheckError) -> ViamAPIKey {
        let keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyID.isEmpty, !key.isEmpty else { throw .rejected }
        let scope = try await KeyCheck.scope(probe: probe(keyID, key), kind: kind, scopeID: scopeID)
        let stored = ViamAPIKey(keyID: keyID, key: key, scope: scope, addedAt: now())
        do {
            try store.save(stored)
        } catch {
            throw .notSaved(String(describing: error))
        }
        tokenSources[keyID] = nil
        rejected.remove(keyID)
        load()
        return stored
    }

    /// Deletes the Keychain item; the key stays valid at Viam.
    public func remove(keyID: String) throws {
        try store.remove(keyID: keyID)
        tokenSources[keyID] = nil
        load()
    }

    /// The key for a location: a key granted that location, else a key granted
    /// its org. With no location, only an org key.
    public func key(org: String, location: String?) -> ViamAPIKey? {
        let inOrg = keys.filter { $0.scope.orgID == org }
        if let location, let key = inOrg.first(where: { $0.scope.locationID == location }) { return key }
        return inOrg.first { !$0.scope.isLocation }
    }

    /// Viam's calls in the org with the key `key(org:location:)` picks; nil when no key covers it.
    public func fleet(org: String, location: String?) -> (any ViamFleet)? {
        key(org: org, location: location).map { makeFleet(org, tokens(for: $0)) }
    }

    /// The locations the keys are granted in the org when no key holds the whole
    /// org, sorted by name; nil when one does, and Viam lists them.
    public func grantedLocations(org: String) -> [ViamLocation]? {
        let inOrg = keys.filter { $0.scope.orgID == org }
        guard !inOrg.contains(where: { !$0.scope.isLocation }) else { return nil }
        var seen = Set<String>()
        return inOrg.compactMap { key in
            key.scope.locationID.flatMap { seen.insert($0).inserted ? ViamLocation(id: $0, name: key.scope.locationName ?? $0) : nil }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func tokens(for key: ViamAPIKey) -> APIKeyTokenSource {
        if let source = tokenSources[key.keyID] { return source }
        let keyID = key.keyID, secret = key.key
        let source = APIKeyTokenSource(keyID: keyID, key: secret, authenticate: authenticate, now: now,
                                       onRejected: { [weak self] in await self?.markRejected(keyID, secret: secret) })
        tokenSources[keyID] = source
        return source
    }

    /// Only while the key is still stored with the secret Viam refused, not after it was replaced.
    private func markRejected(_ keyID: String, secret: String) {
        if keys.contains(where: { $0.keyID == keyID && $0.key == secret }) { rejected.insert(keyID) }
    }

    // MARK: QA keys file

    /// Adds each entry whose key ID isn't stored, through the same check as a
    /// pasted key. A bad entry is reported by its key ID and the rest still load.
    public func importKeys(_ entries: [KeysFile.Entry]) async {
        var problems: [String] = []
        for (index, entry) in entries.enumerated() {
            guard let keyID = entry.keyID else {
                problems.append("Entry \(index + 1): missing key_id")
                continue
            }
            if keys.contains(where: { $0.keyID == keyID }) { continue }
            guard let key = entry.key else {
                problems.append("\(ViamAPIKey.shortID(keyID)): missing key")
                continue
            }
            guard let kind = entry.kind else {
                problems.append("\(ViamAPIKey.shortID(keyID)): missing organization_id or location_id")
                continue
            }
            do {
                try await add(keyID: keyID, key: key, kind: kind, scopeID: entry.scopeID)
            } catch {
                problems.append("\(ViamAPIKey.shortID(keyID)): \(error.message)")
            }
        }
        record(problems)
    }

    public func importKeys(fromFile path: String) async {
        guard let data = FileManager.default.contents(atPath: path), let entries = try? KeysFile.entries(data) else {
            record(["The keys file \(path) couldn't be read as a JSON array of keys."])
            return
        }
        await importKeys(entries)
    }

    private func record(_ problems: [String]) {
        importProblems = problems
        for problem in problems { Self.log.error("Keys file: \(problem, privacy: .public)") }
    }
}
