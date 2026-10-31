/// What Viam said about a stored key.
public enum ValidationResult: Equatable, Sendable {
    case valid(orgName: String)
    /// Viam refused the key: revoked, wrong, or without access to the org.
    case rejected(String)
    /// Viam couldn't be asked. Says nothing about the key.
    case unreachable(String)
}

public protocol CredentialValidator: Sendable {
    func validate(_ credential: OrgCredential) async -> ValidationResult
}
