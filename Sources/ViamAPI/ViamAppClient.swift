public import Foundation
public import ProvisionerKit

/// Calls Viam's AppService with an org API key. Authenticates on first use and
/// keeps the access token for the client's lifetime.
public final class ViamAppClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://app.viam.com")!

    private let keyID: String
    private let key: String
    private let grpc: GRPCWeb
    private let token = TokenCache()

    public init(keyID: String, key: String, baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        self.keyID = keyID
        self.key = key
        grpc = GRPCWeb(baseURL: baseURL, session: session)
    }

    public func organization(id: String) async throws -> (id: String, name: String) {
        var request = Viam_App_V1_GetOrganizationRequest()
        request.organizationID = id
        let response: Viam_App_V1_GetOrganizationResponse = try await grpc.unary(
            "viam.app.v1.AppService/GetOrganization", request, metadata: ["authorization": "Bearer \(accessToken())"])
        return (response.organization.id, response.organization.name)
    }

    public func deleteKey(id: String) async throws {
        var request = Viam_App_V1_DeleteKeyRequest()
        request.id = id
        let _: Viam_App_V1_DeleteKeyResponse = try await grpc.unary(
            "viam.app.v1.AppService/DeleteKey", request, metadata: ["authorization": "Bearer \(accessToken())"])
    }

    private func accessToken() async throws -> String {
        if let cached = await token.value { return cached }
        var request = Proto_Rpc_V1_AuthenticateRequest()
        request.entity = keyID
        request.credentials.type = "api-key"
        request.credentials.payload = key
        let response: Proto_Rpc_V1_AuthenticateResponse = try await grpc.unary("proto.rpc.v1.AuthService/Authenticate", request)
        await token.set(response.accessToken)
        return response.accessToken
    }
}

private actor TokenCache {
    var value: String?
    func set(_ token: String) { value = token }
}

/// Checks a stored key by reading its org from Viam.
public struct ViamCredentialValidator: CredentialValidator {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = ViamAppClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func validate(_ credential: OrgCredential) async -> ValidationResult {
        let client = ViamAppClient(keyID: credential.keyID, key: credential.key, baseURL: baseURL, session: session)
        do {
            return .valid(orgName: try await client.organization(id: credential.orgID).name)
        } catch let error as ViamError {
            switch error {
            case .unauthenticated(let message), .permissionDenied(let message):
                return .rejected(message)
            case .status(let code, let message) where code == 3 || code == 5:
                // INVALID_ARGUMENT, NOT_FOUND: the org ID the key was paired for doesn't resolve.
                return .rejected(message)
            case .status(_, let message):
                return .unreachable(message)
            case .transport(let message):
                return .unreachable(message)
            case .malformedResponse:
                return .unreachable("Viam sent a response the app couldn't read.")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
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
