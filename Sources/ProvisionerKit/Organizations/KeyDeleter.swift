/// Deletes an org API key in Viam, authenticated as another key of the same org.
public protocol KeyDeleter: Sendable {
    func deleteKey(id: String, using credential: OrgCredential) async throws
}
