import Foundation

/// Viam's calls as the key being checked, before it is stored.
public protocol KeyProbe: Sendable {
    /// Exchanges the key for a token; throws `.rejected` when Viam refuses it.
    func authenticate() async throws(KeyCheckError)
    func organizations() async throws(FleetError) -> [ViamOrganization]
    func organization(id: String) async throws(FleetError) -> ViamOrganization
    func locations(org: String) async throws(FleetError) -> [ViamLocation]
    func location(id: String) async throws(FleetError) -> (location: ViamLocation, orgIDs: [String])
}

/// Why a pasted key wasn't stored. No case carries the key.
public enum KeyCheckError: Error, Equatable, Sendable {
    case rejected
    case unreachable(String)
    /// The scope can't be worked out from the key alone.
    case needsScopeID
    /// The key doesn't reach the organization or location ID given with it.
    case outOfReach(String)
    /// Checked, but the Keychain wouldn't store it.
    case notSaved(String)

    public var message: String {
        switch self {
        case .rejected: "Viam rejected this key."
        case .unreachable(let message): "Viam couldn't be reached: \(message)"
        case .needsScopeID: "This key reaches more than one organization or location, or none that Viam will list. Enter the ID it is for."
        case .outOfReach(let id): "This key doesn't reach \(id)."
        case .notSaved(let reason): "Couldn't save the key in the Keychain: \(reason)"
        }
    }
}

/// Whether a key is an organization's or a location's, as the person adding it says.
public enum APIKeyKind: Sendable, Hashable, CaseIterable {
    case organization, location
}

/// Works out what a key is granted, given whether it is an organization's or a
/// location's. Viam answers an org key in a one-location org exactly as it
/// answers that location's key (decision 49), so the kind is never guessed.
public enum KeyCheck {
    public static func scope(probe: any KeyProbe, kind: APIKeyKind, scopeID: String?) async throws(KeyCheckError) -> APIKeyScope {
        try await probe.authenticate()
        let scopeID = scopeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (kind, scopeID.isEmpty) {
        case (.organization, true): return try await discoveredOrganization(probe)
        case (.location, true): return try await discoveredLocation(probe)
        case (.organization, false): return try await organization(probe, id: scopeID)
        case (.location, false): return try await location(probe, id: scopeID)
        }
    }

    private static func discoveredOrganization(_ probe: any KeyProbe) async throws(KeyCheckError) -> APIKeyScope {
        let orgs = try await answer { () async throws(FleetError) in try await probe.organizations() }
        guard let orgs, orgs.count == 1 else { throw .needsScopeID }
        guard try await answer({ () async throws(FleetError) in try await probe.locations(org: orgs[0].id) }) != nil else {
            throw .needsScopeID
        }
        return .organization(id: orgs[0].id, name: orgs[0].name)
    }

    /// Viam lists a location key only the locations it is granted.
    private static func discoveredLocation(_ probe: any KeyProbe) async throws(KeyCheckError) -> APIKeyScope {
        let orgs = try await answer { () async throws(FleetError) in try await probe.organizations() } ?? []
        var granted: [(org: ViamOrganization, location: ViamLocation)] = []
        for org in orgs {
            let locations = try await answer { () async throws(FleetError) in try await probe.locations(org: org.id) } ?? []
            granted += locations.map { (org, $0) }
        }
        guard granted.count == 1, let only = granted.first else { throw .needsScopeID }
        return .location(id: only.location.id, name: only.location.name, orgID: only.org.id, orgName: only.org.name)
    }

    private static func location(_ probe: any KeyProbe, id: String) async throws(KeyCheckError) -> APIKeyScope {
        guard let found = try await answer({ () async throws(FleetError) in try await probe.location(id: id) }),
              let orgID = found.orgIDs.first else {
            throw .outOfReach(id)
        }
        return .location(id: found.location.id, name: found.location.name, orgID: orgID,
                         orgName: try await orgName(probe, orgID))
    }

    private static func organization(_ probe: any KeyProbe, id: String) async throws(KeyCheckError) -> APIKeyScope {
        guard let org = try await answer({ () async throws(FleetError) in try await probe.organization(id: id) }),
              try await answer({ () async throws(FleetError) in try await probe.locations(org: id) }) != nil else {
            throw .outOfReach(id)
        }
        return .organization(id: org.id, name: org.name)
    }

    /// The org's name as the key sees it, or its ID when Viam won't say.
    private static func orgName(_ probe: any KeyProbe, _ orgID: String) async throws(KeyCheckError) -> String {
        if let org = try await answer({ () async throws(FleetError) in try await probe.organization(id: orgID) }) { return org.name }
        let listed = try await answer { () async throws(FleetError) in try await probe.organizations() }
        return listed?.first { $0.id == orgID }?.name ?? orgID
    }

    /// The call's result, nil when Viam refused it or answered with an error.
    private static func answer<T>(_ call: () async throws(FleetError) -> T) async throws(KeyCheckError) -> T? {
        do {
            return try await call()
        } catch {
            switch error {
            case .rejected, .failed: return nil
            case .unreachable(let message): throw .unreachable(message)
            }
        }
    }
}
