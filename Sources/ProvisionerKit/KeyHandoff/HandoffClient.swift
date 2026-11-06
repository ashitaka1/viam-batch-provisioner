public import Foundation

public enum HandoffClientError: Error, Equatable, Sendable {
    /// Another app already answered this handoff.
    case alreadyClaimed
    /// The command ended the session: the operator declined, or it stopped.
    case cancelled
    case timedOut
    /// The command doesn't recognize this session.
    case invalidSession
    case unexpectedStatus(Int)
    case transport(String)
}

/// The app's side of a handoff session with `provisioner-handoff`.
public actor HandoffClient {
    private let link: HandoffLink
    private let session: URLSession
    private let keys = HandoffKeyPair()
    private let appNonce = HandoffNonce.random()
    private var secrets: HandoffSecrets?

    public init(link: HandoffLink, session: URLSession = .shared) {
        self.link = link
        self.session = session
    }

    private var appPublicKey: String { keys.publicKey.base64EncodedString() }
    private var sessionRequest: HandoffSessionRequest {
        HandoffSessionRequest(nonce: link.nonce.base64URL, appPublicKey: appPublicKey)
    }

    /// Commits to the app's key, receives the command's, then reveals. Returns
    /// the org the key is for and the code to show.
    public func hello() async throws -> (orgID: String, orgName: String, code: String) {
        let commitment = HandoffCommitment.make(appPublicKey: keys.publicKey, appNonce: appNonce)
        let reply: HandoffHelloReply = try await post(
            "handoff/hello", HandoffHello(nonce: link.nonce.base64URL, commitment: commitment.base64EncodedString()))
        guard let commandKey = Data(base64Encoded: reply.commandPublicKey) else { throw HandoffError.invalidPeerKey }
        let secrets = try HandoffSecrets(own: keys, peerPublicKey: commandKey, nonce: link.nonce,
                                         commandPublicKey: commandKey, appPublicKey: keys.publicKey, appNonce: appNonce)
        try await send("handoff/reveal", HandoffReveal(nonce: link.nonce.base64URL, appPublicKey: appPublicKey, appNonce: appNonce.base64URL))
        self.secrets = secrets
        return (reply.orgID, reply.orgName, secrets.code)
    }

    /// Waits for the operator to confirm in the terminal, then returns the key.
    public func awaitPayload() async throws -> HandoffPayload {
        guard let secrets else { throw HandoffClientError.invalidSession }
        let sealed: HandoffSealed = try await post("handoff/key", sessionRequest, timeout: 130)
        guard let data = Data(base64Encoded: sealed.sealed) else { throw HandoffError.decryptionFailed }
        return try secrets.open(data)
    }

    public func report(_ outcome: HandoffResult.Outcome, message: String?) async throws {
        let result = HandoffResult(nonce: link.nonce.base64URL, appPublicKey: appPublicKey, outcome: outcome, message: message)
        try await send("handoff/result", result)
    }

    /// Best effort: the command may already be gone.
    public func cancel() async {
        _ = try? await send("handoff/cancel", sessionRequest)
    }

    private func post<Response: Decodable>(_ path: String, _ body: some Encodable, timeout: TimeInterval = 10) async throws -> Response {
        let data = try await send(path, body, timeout: timeout)
        do { return try JSONDecoder().decode(Response.self, from: data) } catch { throw HandoffClientError.unexpectedStatus(200) }
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
            throw HandoffClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 204: return data
        case 409: throw HandoffClientError.alreadyClaimed
        case 410: throw HandoffClientError.cancelled
        case 408: throw HandoffClientError.timedOut
        case 403, 404: throw HandoffClientError.invalidSession
        default: throw HandoffClientError.unexpectedStatus(status)
        }
    }
}
