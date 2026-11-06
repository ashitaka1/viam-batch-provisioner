import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

// MARK: Host

@Test(.timeLimit(.minutes(1))) func helloWithShortCommitmentIsRefusedAndTheSessionStaysOpen() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let short = PairingHello(nonce: host.nonce.base64URL, commitment: Data(count: 16).base64EncodedString())
    await #expect(throws: PairingHostError.unknownSession) { try await host.hello(short) }
    _ = try await app.connect(host)
}

@Test(.timeLimit(.minutes(1))) func revealWithUndecodableAppKeyIsAMismatch() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    let reveal = PairingReveal(nonce: host.nonce.base64URL, appPublicKey: "not base64!", appNonce: app.appNonce.base64URL)
    await #expect(throws: PairingHostError.commitmentMismatch) { try await host.reveal(reveal) }
}

/// The commitment matches, so only the key agreement can refuse the 16-byte key.
@Test(.timeLimit(.minutes(1))) func revealWithWrongLengthAppKeyIsAMismatch() async throws {
    let host = makeHost()
    let shortKey = Data(repeating: 7, count: 16)
    let appNonce = PairingNonce.random()
    let commitment = PairingCommitment.make(appPublicKey: shortKey, appNonce: appNonce)
    _ = try await host.hello(PairingHello(nonce: host.nonce.base64URL, commitment: commitment.base64EncodedString()))
    let reveal = PairingReveal(nonce: host.nonce.base64URL, appPublicKey: shortKey.base64EncodedString(), appNonce: appNonce.base64URL)
    await #expect(throws: PairingHostError.commitmentMismatch) { try await host.reveal(reveal) }
}

@Test(.timeLimit(.minutes(1))) func secondReleaseIsRefused() async throws {
    let host = makeHost()
    _ = try await AppSide(nonce: host.nonce).connect(host)
    try await host.release(payload)
    await #expect(throws: PairingHostError.unknownSession) { try await host.release(payload) }
}

@Test(.timeLimit(.minutes(1))) func anotherAppsReportAndCancelAreRefused() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    try await host.release(payload)
    let other = AppSide(nonce: host.nonce)
    await #expect(throws: PairingHostError.unknownSession) { try await host.report(other.result(.stored)) }
    await #expect(throws: PairingHostError.unknownSession) { try await host.appCancel(other.session) }
    try await host.report(app.result(.stored))
    #expect(await collect(host).last == .result(.stored, message: nil), "the connected app's session survives")
}

// MARK: Over the wire

private func request(_ server: PairingHTTPServer, _ path: String, method: String = "POST", body: some Encodable) async throws -> Int? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/\(path)")!)
    request.httpMethod = method
    if method == "POST" { request.httpBody = try JSONEncoder().encode(body) }
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode
}

private func withServer(_ body: (PairingHost, PairingHTTPServer) async throws -> Void) async throws {
    let host = makeHost()
    let server = try await PairingHTTPServer.start(host: host)
    do { try await body(host, server) } catch { await server.stop(); throw error }
    await server.stop()
}

@Test(.timeLimit(.minutes(1))) func nonPostRequestsAre404() async throws {
    try await withServer { host, server in
        let hello = AppSide(nonce: host.nonce).hello
        for method in ["GET", "PUT", "DELETE"] {
            let status = try await request(server, "pair/hello", method: method, body: hello)
            #expect(status == 404, "\(method) got \(String(describing: status))")
        }
        #expect(try await request(server, "pair/hello", body: hello) == 200, "the session is still open to a POST")
    }
}

@Test(.timeLimit(.minutes(1))) func mismatchedRevealIs403() async throws {
    try await withServer { host, server in
        let app = AppSide(nonce: host.nonce)
        #expect(try await request(server, "pair/hello", body: app.hello) == 200)
        let impostor = AppSide(nonce: host.nonce)
        let status = try await request(server, "pair/reveal", body: impostor.reveal)
        #expect(status == 403, "status \(String(describing: status))")
    }
}

@Test(.timeLimit(.minutes(1))) func requestAfterTheResultIs410() async throws {
    try await withServer { host, server in
        let app = AppSide(nonce: host.nonce)
        _ = try await app.connect(host)
        try await host.release(payload)
        #expect(try await request(server, "pair/result", body: app.result(.stored)) == 204)
        let status = try await request(server, "pair/result", body: app.result(.stored))
        #expect(status == 410, "status \(String(describing: status))")
    }
}

// MARK: Client

/// Answers every request to the pairing link with one canned response.
private final class CannedReply: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func client() -> PairingClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CannedReply.self]
    return PairingClient(link: PairingLink(host: "127.0.0.1", port: 9, nonce: .random()), session: URLSession(configuration: configuration))
}

private func helloReply(commandPublicKey: String) throws -> Data {
    try JSONEncoder().encode(PairingHelloReply(commandPublicKey: commandPublicKey, orgID: "o1", orgName: "Acme"))
}

/// CannedReply's response is shared, so these run one at a time.
@Suite(.serialized) struct PairingClientReplies {
    @Test func unknownStatusIsUnexpected() async {
        CannedReply.status = 500
        CannedReply.body = Data()
        await #expect(throws: PairingClientError.unexpectedStatus(500)) { _ = try await client().hello() }
    }

    @Test func undecodableReplyIsUnexpected() async {
        CannedReply.status = 200
        CannedReply.body = Data("not json".utf8)
        await #expect(throws: PairingClientError.unexpectedStatus(200)) { _ = try await client().hello() }
    }

    @Test func undecodableCommandKeyIsInvalid() async throws {
        CannedReply.status = 200
        CannedReply.body = try helloReply(commandPublicKey: "not base64!")
        await #expect(throws: PairingError.invalidPeerKey) { _ = try await client().hello() }
    }

    @Test func wrongLengthCommandKeyIsInvalid() async throws {
        CannedReply.status = 200
        CannedReply.body = try helloReply(commandPublicKey: Data(count: 16).base64EncodedString())
        await #expect(throws: PairingError.invalidPeerKey) { _ = try await client().hello() }
    }
}
