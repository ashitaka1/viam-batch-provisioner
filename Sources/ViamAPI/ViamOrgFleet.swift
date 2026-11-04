public import Foundation
public import ProvisionerKit

/// The Viam calls machine creation needs, in one org, as the signed-in user.
public struct ViamOrgFleet: ViamFleet {
    private let orgID: String
    private let client: ViamAppClient

    public init(orgID: String, tokens: any BearerTokenProvider, baseURL: URL = ViamAppClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.orgID = orgID
        client = ViamAppClient(tokens: tokens, baseURL: baseURL, session: session)
    }

    /// The same calls made with an org API key.
    public init(orgID: String, keyID: String, key: String, baseURL: URL = ViamAppClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.orgID = orgID
        client = ViamAppClient(keyID: keyID, key: key, baseURL: baseURL, session: session)
    }

    public func locations() async throws(FleetError) -> [ViamLocation] {
        try await fleetCall { try await client.locations(organizationID: orgID).map { ViamLocation(id: $0.id, name: $0.name) } }
    }

    public func machines(location: String) async throws(FleetError) -> [ViamMachine] {
        try await fleetCall { try await client.robots(locationID: location).map { ViamMachine(id: $0.id, name: $0.name) } }
    }

    public func createMachine(name: String, location: String) async throws(FleetError) -> String {
        try await fleetCall { try await client.newRobot(name: name, location: location) }
    }

    public func mainPart(machine: String) async throws(FleetError) -> MachinePart {
        let parts = try await fleetCall { try await client.robotParts(robotID: machine) }
        guard let main = parts.first(where: \.mainPart) else { throw .failed("Machine \(machine) has no main part.") }
        return MachinePart(id: main.id, secret: main.secret)
    }

    public func deleteMachine(id: String) async throws(FleetError) {
        try await fleetCall { try await client.deleteRobot(id: id) }
    }
}

/// The organizations the signed-in user can see.
public struct ViamOrganizationLister: OrganizationLister {
    private let client: ViamAppClient

    public init(tokens: any BearerTokenProvider, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        client = ViamAppClient(tokens: tokens, baseURL: baseURL, session: session)
    }

    public func organizations() async throws(FleetError) -> [ViamOrganization] {
        try await fleetCall { try await client.organizations() }
    }
}

/// Sorts Viam's errors by what a caller can conclude from them. Viam's message is
/// kept as is, so a name it refuses is explained in its own words.
func fleetCall<T>(_ call: () async throws -> T) async throws(FleetError) -> T {
    do {
        return try await call()
    } catch let error as ViamError {
        switch error {
        case .unauthenticated(let message), .permissionDenied(let message):
            throw .rejected(message)
        case .status(let code, let message) where [1, 2, 4, 13, 14].contains(code):
            // CANCELLED, UNKNOWN, DEADLINE_EXCEEDED, INTERNAL, UNAVAILABLE: the call may have run.
            throw .unreachable(message)
        case .status(_, let message):
            throw .failed(message)
        case .transport(let message):
            throw .unreachable(message)
        case .malformedResponse:
            throw .unreachable(error.description)
        }
    } catch ViamCLIError.notLoggedIn {
        throw .rejected("Sign in to Viam.")
    } catch ViamCLIError.notInstalled {
        throw .rejected("Install the viam CLI.")
    } catch ViamCLIError.tokenUnavailable {
        throw .unreachable("The viam CLI couldn't give the app its login.")
    } catch ViamCLIError.failed(let stderr) {
        throw .unreachable(stderr)
    } catch {
        throw .unreachable(error.localizedDescription)
    }
}
