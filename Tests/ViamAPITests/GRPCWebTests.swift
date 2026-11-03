import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI


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


// MARK: - Malformed responses and other statuses

private func validate(_ reply: @escaping (URLRequest) -> StubProtocol.Reply) async -> ValidationResult {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : reply(request)
    }
    return await ViamCredentialValidator(baseURL: base, session: session).validate(credential)
}

private func call(_ reply: @escaping (URLRequest) -> StubProtocol.Reply) async throws {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : reply(request)
    }
    _ = try await ViamAppClient(keyID: "kid", key: "kval", baseURL: base, session: session).organization(id: "o1")
}

@Test(arguments: [3, 5]) func unknownOrgIsRejection(code: Int) async {
    #expect(await validate { _ in trailerStatus(code, "no such org") } == .rejected("no such org"))
}

@Test func httpErrorIsTransport() async {
    await #expect(throws: ViamError.transport("HTTP 503")) {
        try await call { _ in StubProtocol.Reply(status: 503) }
    }
}

@Test func truncatedFrameIsMalformed() async {
    await #expect(throws: ViamError.malformedResponse) {
        try await call { _ in StubProtocol.Reply(body: frame(0, Data([1, 2, 3, 4, 5])).prefix(7)) }
    }
}

@Test func shortTrailingBytesAreMalformed() async {
    await #expect(throws: ViamError.malformedResponse) {
        try await call { _ in
            var reply = ok(organization("o1", "Acme"))
            reply.body.append(contentsOf: [0, 0])
            return reply
        }
    }
}

@Test func okWithoutMessageIsMalformed() async {
    await #expect(throws: ViamError.malformedResponse) {
        try await call { _ in StubProtocol.Reply(body: frame(0x80, Data("grpc-status:0\r\n".utf8))) }
    }
}

@Test func missingStatusIsMalformed() async {
    await #expect(throws: ViamError.malformedResponse) {
        try await call { _ in StubProtocol.Reply(body: frame(0, try! organization("o1", "Acme").serializedData())) }
    }
}

@Test func malformedResponseIsNotRejection() async {
    let result = await validate { _ in StubProtocol.Reply(body: Data([0, 0])) }
    guard case .unreachable = result else { Issue.record("expected .unreachable, got \(result)"); return }
}

// MARK: - Key deletion

@Test func deleteKeySendsKeyIDAuthenticatedAsTheCredential() async throws {
    let seen = Locked<[(path: String, body: Data, auth: String?)]>([])
    let base = StubProtocol.register { request, body in
        seen.withLock { $0.append((request.url!.path, body, request.value(forHTTPHeaderField: "authorization"))) }
        return request.url!.path.hasSuffix("Authenticate") ? ok(authenticated(token: "tok-new")) : ok(Viam_App_V1_DeleteKeyResponse())
    }
    try await ViamKeyDeleter(baseURL: base, session: session).deleteKey(id: "kid-old", using: credential)
    let calls = seen.withLock { $0 }
    #expect(calls.map(\.path) == ["/proto.rpc.v1.AuthService/Authenticate", "/viam.app.v1.AppService/DeleteKey"])
    #expect(try unframe(Proto_Rpc_V1_AuthenticateRequest.self, calls[0].body).entity == "kid")
    #expect(try unframe(Viam_App_V1_DeleteKeyRequest.self, calls[1].body).id == "kid-old")
    #expect(calls[1].auth == "Bearer tok-new")
}

@Test func deleteKeyFailureDescribesViamsMessage() async {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : trailerStatus(7, "not an owner")
    }
    do {
        try await ViamKeyDeleter(baseURL: base, session: session).deleteKey(id: "kid-old", using: credential)
        Issue.record("expected the deletion to fail")
    } catch {
        #expect("\(error)".contains("not an owner"))
    }
}

@Test func deletingAKeyAlreadyGoneSucceeds() async throws {
    let base = StubProtocol.register { request, _ in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : trailerStatus(5, "Does not exist or you don't have permissions to view it")
    }
    try await ViamKeyDeleter(baseURL: base, session: session).deleteKey(id: "kid-old", using: credential)
}
