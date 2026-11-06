public import Foundation
public import ProvisionerKit
import SwiftProtobuf

/// Calls Viam's AppService as the signed-in user's bearer token, or as an org API key.
public final class ViamAppClient: Sendable {
    public static let defaultBaseURL = ViamSession.defaultBaseURL

    private enum Auth {
        /// Authenticates on first use and keeps the access token for the client's lifetime.
        case apiKey(id: String, key: String, cache: TokenCache)
        case bearer(any BearerTokenProvider)
    }

    private let auth: Auth
    private let grpc: GRPCWeb

    public init(keyID: String, key: String, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        auth = .apiKey(id: keyID, key: key, cache: TokenCache())
        grpc = GRPCWeb(baseURL: baseURL, session: session)
    }

    public init(tokens: any BearerTokenProvider, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        auth = .bearer(tokens)
        grpc = GRPCWeb(baseURL: baseURL, session: session)
    }

    public func organization(id: String) async throws -> (id: String, name: String) {
        var request = Viam_App_V1_GetOrganizationRequest()
        request.organizationID = id
        let response: Viam_App_V1_GetOrganizationResponse = try await appService("GetOrganization", request)
        return (response.organization.id, response.organization.name)
    }

    /// The organizations the caller can see, sorted by name ignoring case.
    public func organizations() async throws -> [ViamOrganization] {
        let response: Viam_App_V1_ListOrganizationsResponse = try await appService(
            "ListOrganizations", Viam_App_V1_ListOrganizationsRequest())
        return response.organizations.map { ViamOrganization(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func deleteKey(id: String) async throws {
        var request = Viam_App_V1_DeleteKeyRequest()
        request.id = id
        let _: Viam_App_V1_DeleteKeyResponse = try await appService("DeleteKey", request)
    }

    public func locations(organizationID: String) async throws -> [(id: String, name: String)] {
        var request = Viam_App_V1_ListLocationsRequest()
        request.organizationID = organizationID
        let response: Viam_App_V1_ListLocationsResponse = try await appService("ListLocations", request)
        return response.locations.map { ($0.id, $0.name) }
    }

    public func location(id: String) async throws -> (id: String, name: String, organizationIDs: [String]) {
        var request = Viam_App_V1_GetLocationRequest()
        request.locationID = id
        let response: Viam_App_V1_GetLocationResponse = try await appService("GetLocation", request)
        return (response.location.id, response.location.name, response.location.organizations.map(\.organizationID))
    }

    public func robots(locationID: String) async throws -> [(id: String, name: String)] {
        var request = Viam_App_V1_ListRobotsRequest()
        request.locationID = locationID
        let response: Viam_App_V1_ListRobotsResponse = try await appService("ListRobots", request)
        return response.robots.map { ($0.id, $0.name) }
    }

    /// Returns the new machine's ID.
    public func newRobot(name: String, location: String) async throws -> String {
        var request = Viam_App_V1_NewRobotRequest()
        request.name = name
        request.location = location
        let response: Viam_App_V1_NewRobotResponse = try await appService("NewRobot", request)
        return response.id
    }

    public func robotParts(robotID: String) async throws -> [Viam_App_V1_RobotPart] {
        var request = Viam_App_V1_GetRobotPartsRequest()
        request.robotID = robotID
        let response: Viam_App_V1_GetRobotPartsResponse = try await appService("GetRobotParts", request)
        return response.parts
    }

    public func robotPart(id: String) async throws -> (id: String, secret: String) {
        var request = Viam_App_V1_GetRobotPartRequest()
        request.id = id
        let response: Viam_App_V1_GetRobotPartResponse = try await appService("GetRobotPart", request)
        return (response.part.id, response.part.secret)
    }

    public func deleteRobot(id: String) async throws {
        var request = Viam_App_V1_DeleteRobotRequest()
        request.id = id
        let _: Viam_App_V1_DeleteRobotResponse = try await appService("DeleteRobot", request)
    }

    /// A bearer token Viam refuses is refreshed once and the call retried.
    private func appService<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        _ method: String, _ request: Request
    ) async throws -> Response {
        let path = "viam.app.v1.AppService/\(method)"
        switch auth {
        case .apiKey(let id, let key, let cache):
            let token = try await apiKeyToken(id: id, key: key, cache: cache)
            return try await grpc.unary(path, request, metadata: ["authorization": "Bearer \(token)"])
        case .bearer(let tokens):
            do {
                let token = try await tokens.token(refresh: false)
                return try await grpc.unary(path, request, metadata: ["authorization": "Bearer \(token)"])
            } catch ViamError.unauthenticated {
                let token = try await tokens.token(refresh: true)
                do {
                    return try await grpc.unary(path, request, metadata: ["authorization": "Bearer \(token)"])
                } catch ViamError.unauthenticated(let message) {
                    await tokens.rejected()
                    throw ViamError.unauthenticated(message)
                }
            }
        }
    }

    private func apiKeyToken(id: String, key: String, cache: TokenCache) async throws -> String {
        if let cached = await cache.value { return cached }
        let token = try await Self.authenticate(keyID: id, key: key, grpc: grpc)
        await cache.set(token)
        return token
    }

    /// Exchanges an API key for an access token through `AuthService/Authenticate`.
    /// Throws `APIKeyRefused` when Viam refuses the key.
    public static func authenticate(keyID: String, key: String, baseURL: URL = ViamAppClient.defaultBaseURL,
                                    session: URLSession = .shared) async throws -> String {
        do {
            return try await authenticate(keyID: keyID, key: key, grpc: GRPCWeb(baseURL: baseURL, session: session))
        } catch ViamError.unauthenticated, ViamError.permissionDenied {
            throw APIKeyRefused()
        }
    }

    private static func authenticate(keyID: String, key: String, grpc: GRPCWeb) async throws -> String {
        var request = Proto_Rpc_V1_AuthenticateRequest()
        request.entity = keyID
        request.credentials.type = "api-key"
        request.credentials.payload = key
        let response: Proto_Rpc_V1_AuthenticateResponse = try await grpc.unary("proto.rpc.v1.AuthService/Authenticate", request)
        return response.accessToken
    }
}

private actor TokenCache {
    var value: String?
    func set(_ token: String) { value = token }
}

public struct ViamKeyDeleter: KeyDeleter {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// A key Viam doesn't find (NOT_FOUND) counts as deleted.
    public func deleteKey(id: String, using credential: OrgCredential) async throws {
        do {
            try await ViamAppClient(keyID: credential.keyID, key: credential.key, baseURL: baseURL, session: session).deleteKey(id: id)
        } catch ViamError.status(code: 5, _) {}
    }
}
