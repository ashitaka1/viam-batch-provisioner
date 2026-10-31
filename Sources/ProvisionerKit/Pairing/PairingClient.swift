public import Foundation

public enum PairingClientError: Error, Equatable, Sendable {
    /// Another app already answered this pairing.
    case alreadyPaired
    /// The command ended the session: the operator declined, or it stopped.
    case cancelled
    case timedOut
    /// The command doesn't recognize this session.
    case invalidSession
    case unexpectedStatus(Int)
    case transport(String)
}

/// The app's side of a pairing session with `just pair-app`.
public actor PairingClient {
    private let link: PairingLink
    private let session: URLSession
    private let keys = PairingKeyPair()
    private var secrets: PairingSecrets?

    public init(link: PairingLink, session: URLSession = .shared) {
        self.link = link
        self.session = session
    }

    private var appPublicKey: String { keys.publicKey.base64EncodedString() }
    private var sessionRequest: PairingSessionRequest {
        PairingSessionRequest(nonce: link.nonce.base64URL, appPublicKey: appPublicKey)
    }

    /// Exchanges keys. Returns the org being paired and the code to show.
    public func hello() async throws -> (orgID: String, orgName: String, code: String) {
        let reply: PairingHelloReply = try await post("pair/hello", PairingHello(nonce: link.nonce.base64URL, appPublicKey: appPublicKey))
        guard let commandKey = Data(base64Encoded: reply.commandPublicKey) else { throw PairingError.invalidPeerKey }
        let secrets = try PairingSecrets(own: keys, peerPublicKey: commandKey, nonce: link.nonce,
                                         commandPublicKey: commandKey, appPublicKey: keys.publicKey)
        self.secrets = secrets
        return (reply.orgID, reply.orgName, secrets.code)
    }

    /// Waits for the operator to confirm in the terminal, then returns the key.
    public func awaitPayload() async throws -> PairingPayload {
        guard let secrets else { throw PairingClientError.invalidSession }
        let sealed: PairingSealed = try await post("pair/key", sessionRequest, timeout: 130)
        guard let data = Data(base64Encoded: sealed.sealed) else { throw PairingError.decryptionFailed }
        return try secrets.open(data)
    }

    public func report(_ outcome: PairingResult.Outcome, message: String?) async throws {
        let result = PairingResult(nonce: link.nonce.base64URL, appPublicKey: appPublicKey, outcome: outcome, message: message)
        try await send("pair/result", result)
    }

    /// Best effort: the command may already be gone.
    public func cancel() async {
        _ = try? await send("pair/cancel", sessionRequest)
    }

    private func post<Response: Decodable>(_ path: String, _ body: some Encodable, timeout: TimeInterval = 10) async throws -> Response {
        let data = try await send(path, body, timeout: timeout)
        do { return try JSONDecoder().decode(Response.self, from: data) } catch { throw PairingClientError.unexpectedStatus(200) }
    }

    @discardableResult
    private func send(_ path: String, _ body: some Encodable, timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: link.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 204: return data
        case 409: throw PairingClientError.alreadyPaired
        case 410: throw PairingClientError.cancelled
        case 408: throw PairingClientError.timedOut
        case 403, 404: throw PairingClientError.invalidSession
        default: throw PairingClientError.unexpectedStatus(status)
        }
    }
}
