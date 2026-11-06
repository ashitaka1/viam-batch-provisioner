/// A Viam organization the signed-in account can see.
public struct ViamOrganization: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol OrganizationLister: Sendable {
    func organizations() async throws(FleetError) -> [ViamOrganization]
    /// One organization, for a credential Viam won't list organizations for.
    func organization(id: String) async throws(FleetError) -> ViamOrganization
}

extension OrganizationLister {
    public func organization(id: String) async throws(FleetError) -> ViamOrganization {
        throw .rejected("Organization \(id) can't be read.")
    }
}

/// What the app knows of the signed-in account's organizations.
public enum AccountOrgs: Sendable, Equatable {
    case signedOut
    /// Signed in, but the list is loading or couldn't be read.
    case unknown
    case known([ViamOrganization])
}
