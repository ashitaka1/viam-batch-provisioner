public import Foundation
internal import ProvisionerAPI

public struct ProvisionRequest: Sendable, Equatable {
    public var name: String
    /// The machine's `viam.json`.
    public var credentialsJSON: Data?
    public var environment: EnvironmentConfig?

    public init(name: String, credentialsJSON: Data? = nil, environment: EnvironmentConfig? = nil) {
        self.name = name
        self.credentialsJSON = credentialsJSON
        self.environment = environment
    }

    func wire() throws(ProvisionerError) -> Components.Schemas.ProvisionRequest {
        var credentials: Components.Schemas.ViamCredentials?
        if let credentialsJSON {
            guard let decoded = try? WireCoding.decoder.decode(Components.Schemas.ViamCredentials.self, from: credentialsJSON),
                  !decoded.cloud.id.isEmpty, !decoded.cloud.secret.isEmpty
            else { throw .invalidCredentials }
            credentials = decoded
        }
        return Components.Schemas.ProvisionRequest(name: name, credentials: credentials, environment: environment?.wire())
    }
}
