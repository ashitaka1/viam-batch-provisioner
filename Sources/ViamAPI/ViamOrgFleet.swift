public import Foundation
public import ProvisionerKit

/// The Viam calls machine creation needs, made with one org's paired key.
public struct ViamOrgFleet: ViamFleet {
    private let orgID: String
    private let client: ViamAppClient

    public init(credential: OrgCredential, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        orgID = credential.orgID
        client = ViamAppClient(keyID: credential.keyID, key: credential.key, baseURL: baseURL, session: session)
    }

    public func locations() async throws(FleetError) -> [ViamLocation] {
        try await mapped { try await client.locations(organizationID: orgID).map { ViamLocation(id: $0.id, name: $0.name) } }
    }

    public func machines(location: String) async throws(FleetError) -> [ViamMachine] {
        try await mapped { try await client.robots(locationID: location).map { ViamMachine(id: $0.id, name: $0.name) } }
    }

    public func createMachine(name: String, location: String) async throws(FleetError) -> String {
        try await mapped { try await client.newRobot(name: name, location: location) }
    }

    public func mainPart(machine: String) async throws(FleetError) -> MachinePart {
        let parts = try await mapped { try await client.robotParts(robotID: machine) }
        guard let main = parts.first(where: \.mainPart) else { throw .failed("Machine \(machine) has no main part.") }
        return MachinePart(id: main.id, secret: main.secret)
    }

    public func deleteMachine(id: String) async throws(FleetError) {
        try await mapped { try await client.deleteRobot(id: id) }
    }

    /// Sorts Viam's errors by what the batch can conclude from them. Viam's
    /// message is kept as is, so a name it refuses is explained in its own words.
    private func mapped<T>(_ call: () async throws -> T) async throws(FleetError) -> T {
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
        } catch {
            throw .unreachable(error.localizedDescription)
        }
    }
}
