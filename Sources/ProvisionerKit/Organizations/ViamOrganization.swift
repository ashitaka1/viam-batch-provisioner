/// A Viam organization a stored key reaches.
public struct ViamOrganization: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the app knows of the organizations its keys reach.
public enum AccountOrgs: Sendable, Equatable {
    /// No key is stored.
    case signedOut
    /// The keys haven't been read yet.
    case unknown
    case known([ViamOrganization])
}
