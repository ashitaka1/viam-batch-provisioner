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

/// Deletes an org API key in Viam, authenticated as another key of the same org.
public protocol KeyDeleter: Sendable {
    func deleteKey(id: String, using credential: OrgCredential) async throws
}
