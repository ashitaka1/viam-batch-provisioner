/// What an API key reaches, as the sign-in status names it. Viam doesn't tell a
/// key its own grant, so the scope is read from what the key can see: a key Viam
/// lists an org's locations for is taken to hold the org.
public enum KeyScope: Equatable, Sendable, CustomStringConvertible {
    case organization(String)
    case organizations(Int)
    case location(String)
    case locations(Int, organization: String)

    /// `locations` are the single org's, nil while unknown; `grantsOnly` when
    /// they were read one by one after Viam refused the list.
    public init?(organizations: [ViamOrganization], locations: [ViamLocation]?, grantsOnly: Bool) {
        guard let org = organizations.first else { return nil }
        guard organizations.count == 1 else {
            self = .organizations(organizations.count)
            return
        }
        guard grantsOnly, let locations, !locations.isEmpty else {
            self = .organization(org.name)
            return
        }
        self = locations.count == 1 ? .location(locations[0].name) : .locations(locations.count, organization: org.name)
    }

    public var description: String {
        switch self {
        case .organization(let name): "organization \(name)"
        case .organizations(let count): "\(count) organizations"
        case .location(let name): "location \(name)"
        case .locations(let count, let org): "\(count) locations in \(org)"
        }
    }
}
