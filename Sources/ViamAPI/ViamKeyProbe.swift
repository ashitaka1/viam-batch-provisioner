public import Foundation
public import ProvisionerKit

/// Viam's calls as a pasted key, to work out its scope before it is stored.
public struct ViamKeyProbe: KeyProbe {
    private let tokens: APIKeyTokenSource
    private let client: ViamAppClient

    public init(keyID: String, key: String, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        tokens = APIKeyTokenSource(keyID: keyID, key: key, authenticate: {
            try await ViamAppClient.authenticate(keyID: $0, key: $1, baseURL: baseURL, session: session)
        })
        client = ViamAppClient(tokens: tokens, baseURL: baseURL, session: session)
    }

    public func authenticate() async throws(KeyCheckError) {
        do {
            _ = try await tokens.token(refresh: false)
        } catch is APIKeyRefused {
            throw .rejected
        } catch let error as ViamError {
            throw .unreachable(error.description)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
    }

    public func organizations() async throws(FleetError) -> [ViamOrganization] {
        try await fleetCall { try await client.organizations() }
    }

    public func organization(id: String) async throws(FleetError) -> ViamOrganization {
        let org = try await fleetCall { try await client.organization(id: id) }
        return ViamOrganization(id: org.id, name: org.name)
    }

    public func locations(org: String) async throws(FleetError) -> [ViamLocation] {
        try await fleetCall { try await client.locations(organizationID: org).map { ViamLocation(id: $0.id, name: $0.name) } }
    }

    /// `orgIDs` start with the location's primary owner.
    public func location(id: String) async throws(FleetError) -> (location: ViamLocation, orgIDs: [String]) {
        let location = try await fleetCall { try await client.location(id: id) }
        return (ViamLocation(id: location.id, name: location.name), location.organizationIDs)
    }
}
