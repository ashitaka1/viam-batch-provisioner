import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI

// MARK: - Stub server

/// Serves canned gRPC-web responses per host; each test uses its own host so
/// tests can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var headers: [String: String] = ["content-type": "application/grpc-web+proto"]
        var body = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var handlers: [String: (URLRequest, Data) -> Reply] = [:]
    static let lock = NSLock()

    static func register(_ handler: @escaping (URLRequest, Data) -> Reply) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { handlers[host] = handler }
        return URL(string: "https://\(host)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url!.host!] }!
        let reply = handler(request, Self.body(of: request))
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}()

private func frame(_ flag: UInt8, _ payload: Data) -> Data {
    var data = Data([flag])
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
    return data + payload
}

private func ok(_ message: some SwiftProtobuf.Message) -> StubProtocol.Reply {
    StubProtocol.Reply(body: frame(0, try! message.serializedData()) + frame(0x80, Data("grpc-status:0\r\ngrpc-message:\r\n".utf8)))
}

private func trailerStatus(_ code: Int, _ message: String) -> StubProtocol.Reply {
    StubProtocol.Reply(body: frame(0x80, Data("grpc-status:\(code)\r\ngrpc-message:\(message)\r\n".utf8)))
}

private func unframe<M: SwiftProtobuf.Message>(_ type: M.Type, _ body: Data) throws -> M {
    try M(serializedBytes: body.dropFirst(5))
}

private func authenticated(token: String = "tok") -> Proto_Rpc_V1_AuthenticateResponse {
    var response = Proto_Rpc_V1_AuthenticateResponse()
    response.accessToken = token
    return response
}

private func organization(_ id: String, _ name: String) -> Viam_App_V1_GetOrganizationResponse {
    var response = Viam_App_V1_GetOrganizationResponse()
    response.organization.id = id
    response.organization.name = name
    return response
}

private let credential = OrgCredential(
    PairingPayload(orgID: "o1", orgName: "Acme", keyID: "kid", key: "kval", keyName: "provisioner-app studio 2026-10-31"),
    addedAt: Date(timeIntervalSince1970: 0))

// MARK: - Tests

@Test func framesRequestAsGRPCWeb() async throws {
    let seen = Locked<[URLRequest]>([])
    let base = StubProtocol.register { request, _ in
        seen.withLock { $0.append(request) }
        return request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : ok(organization("o1", "Acme"))
    }
    _ = try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    let request = try #require(seen.withLock { $0.last })
    #expect(request.url?.path == "/viam.app.v1.AppService/GetOrganization")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/grpc-web+proto")
    #expect(request.value(forHTTPHeaderField: "x-grpc-web") == "1")
}

@Test func framesBodyWithLengthPrefix() async throws {
    let bodies = Locked<[Data]>([])
    let base = StubProtocol.register { request, body in
        bodies.withLock { $0.append(body) }
        return request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : ok(organization("o1", "Acme"))
    }
    _ = try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    let body = try #require(bodies.withLock { $0.last })
    #expect(body.first == 0, "data frame flag")
    let length = body.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
    #expect(length == body.count - 5, "length prefix \(length), body \(body.count - 5)")
    #expect(try unframe(Viam_App_V1_GetOrganizationRequest.self, body).organizationID == "o1")
}

@Test func authenticatesThenSendsBearer() async throws {
    let requests = Locked<[(URLRequest, Data)]>([])
    let base = StubProtocol.register { request, body in
        requests.withLock { $0.append((request, body)) }
        return request.url!.path.hasSuffix("Authenticate") ? ok(authenticated(token: "tok-1")) : ok(organization("o1", "Acme"))
    }
    let org = try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    #expect(org.id == "o1" && org.name == "Acme")
    let all = requests.withLock { $0 }
    try #require(all.count == 2)
    #expect(all[0].0.url?.path == "/proto.rpc.v1.AuthService/Authenticate")
    let auth = try unframe(Proto_Rpc_V1_AuthenticateRequest.self, all[0].1)
    #expect(auth.entity == "kid")
    #expect(auth.credentials.type == "api-key")
    #expect(auth.credentials.payload == "kval")
    #expect(all[1].0.value(forHTTPHeaderField: "authorization") == "Bearer tok-1")
}

@Test func reusesAccessToken() async throws {
    let authCount = Locked(0)
    let base = StubProtocol.register { request, _ in
        if request.url!.path.hasSuffix("Authenticate") {
            authCount.withLock { $0 += 1 }
            return ok(authenticated())
        }
        return ok(organization("o1", "Acme"))
    }
    let client = ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session)
    _ = try await client.organization(id: "o1")
    _ = try await client.organization(id: "o1")
    #expect(authCount.withLock { $0 } == 1, "authenticated \(authCount.withLock { $0 }) times")
}

@Test func readsStatusFromTrailerFrame() async {
    let base = StubProtocol.register { _, _ in trailerStatus(16, "bad key") }
    await #expect(throws: ViamError.unauthenticated("bad key")) {
        try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    }
}

@Test func readsStatusFromHeaders() async {
    let base = StubProtocol.register { request, _ in
        if request.url!.path.hasSuffix("Authenticate") { return ok(authenticated()) }
        var reply = StubProtocol.Reply()
        reply.headers["grpc-status"] = "7"
        reply.headers["grpc-message"] = "not%20yours"
        return reply
    }
    await #expect(throws: ViamError.permissionDenied("not yours")) {
        try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    }
}

@Test func otherStatusCarriesCode() async {
    let base = StubProtocol.register { _, _ in trailerStatus(14, "unavailable") }
    await #expect(throws: ViamError.status(code: 14, message: "unavailable")) {
        try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
    }
}

@Test func validResultCarriesOrgName() async {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : ok(organization("o1", "Acme Robotics"))
    }
    let result = await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
    #expect(result == .valid(orgName: "Acme Robotics"))
}

@Test func unauthenticatedIsRejection() async {
    let base = StubProtocol.register { _, _ in trailerStatus(16, "bad key") }
    let result = await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
    #expect(result == .rejected("bad key"))
}

@Test func permissionDeniedIsRejection() async {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : trailerStatus(7, "no access")
    }
    let result = await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
    #expect(result == .rejected("no access"))
}

@Test func transportErrorIsNotRejection() async {
    let base = StubProtocol.register { _, _ in StubProtocol.Reply(error: URLError(.notConnectedToInternet)) }
    let result = await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
    guard case .unreachable = result else {
        Issue.record("expected .unreachable, got \(result)")
        return
    }
}

@Test func serverUnavailableIsNotRejection() async {
    let base = StubProtocol.register { _, _ in trailerStatus(14, "unavailable") }
    let result = await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
    guard case .unreachable = result else {
        Issue.record("expected .unreachable, got \(result)")
        return
    }
}

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
