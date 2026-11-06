import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI

private typealias Seen = Locked<[(path: String, authorization: String?)]>

private func client(_ tokens: ScriptedTokens, seen: Seen, _ reply: @escaping (Int) -> StubProtocol.Reply) -> ViamAppClient {
    let base = StubProtocol.register { request, _ in
        let count = seen.withLock {
            $0.append((request.url!.path, request.value(forHTTPHeaderField: "authorization")))
            return $0.count
        }
        return reply(count)
    }
    return ViamAppClient(tokens: tokens, baseURL: base, session: session)
}

private func organizations(_ pairs: [(String, String)]) -> Viam_App_V1_ListOrganizationsResponse {
    var response = Viam_App_V1_ListOrganizationsResponse()
    response.organizations = pairs.map { id, name in
        var org = Viam_App_V1_Organization()
        org.id = id
        org.name = name
        return org
    }
    return response
}

@Test func bearerTokenIsSent() async throws {
    let seen = Seen([])
    let client = client(ScriptedTokens(["t1"]), seen: seen) { _ in ok(Viam_App_V1_ListLocationsResponse()) }
    _ = try await client.locations(organizationID: "o1")
    #expect(seen.withLock { $0.map(\.path) } == ["/viam.app.v1.AppService/ListLocations"])
    #expect(seen.withLock { $0.map(\.authorization) } == ["Bearer t1"])
}

@Test func unauthenticatedRetriesOnceWithFreshToken() async throws {
    let seen = Seen([])
    let tokens = ScriptedTokens(["t1", "t2"])
    let client = client(tokens, seen: seen) { count in
        count == 1 ? trailerStatus(16, "expired") : ok(Viam_App_V1_ListLocationsResponse())
    }
    _ = try await client.locations(organizationID: "o1")
    #expect(seen.withLock { $0.map(\.authorization) } == ["Bearer t1", "Bearer t2"])
    #expect(await tokens.refreshes == [false, true])
}

@Test func secondUnauthenticatedTellsTheProviderAndThrows() async {
    let seen = Seen([])
    let tokens = ScriptedTokens(["t1", "t2"])
    let client = client(tokens, seen: seen) { _ in trailerStatus(16, "signed out") }
    await #expect(throws: ViamError.unauthenticated("signed out")) { _ = try await client.locations(organizationID: "o1") }
    #expect(seen.withLock { $0.count } == 2, "expected one retry")
    #expect(await tokens.rejections == 1, "the provider wasn't told its refreshed token was refused")
}

@Test(arguments: [7, 13])
func otherStatusesAreNotRetried(code: Int) async {
    let seen = Seen([])
    let tokens = ScriptedTokens(["t1", "t2"])
    let client = client(tokens, seen: seen) { _ in trailerStatus(code, "no") }
    await #expect(throws: (any Error).self) { _ = try await client.locations(organizationID: "o1") }
    #expect(seen.withLock { $0.count } == 1, "status \(code) was retried")
    #expect(await tokens.refreshes == [false])
    #expect(await tokens.rejections == 0)
}

@Test(arguments: [
    (ViamCLIError.notLoggedIn, FleetError.rejected("Sign in to Viam.")),
    (.notInstalled, .rejected("Install the viam CLI.")),
    (.tokenUnavailable, .unreachable("The viam CLI couldn't give the app its login.")),
    (.failed("Error: boom"), .unreachable("Error: boom")),
])
func providerFailureReachesTheCallerWithoutARequest(failure: ViamCLIError, expected: FleetError) async {
    let seen = Seen([])
    let fleet = ViamOrgFleet(orgID: "o1", tokens: ScriptedTokens(failing: failure), baseURL: StubProtocol.register { request, _ in
        seen.withLock { $0.append((request.url!.path, nil)) }
        return ok(Viam_App_V1_ListLocationsResponse())
    }, session: session)
    await #expect(throws: expected) { _ = try await fleet.locations() }
    #expect(seen.withLock { $0.isEmpty }, "a request went out without a token")
}

/// An error from outside Viam and its CLI leaves the outcome unknown.
@Test func unrecognizedProviderFailureIsUnreachable() async {
    struct KeychainLocked: LocalizedError { var errorDescription: String? { "The keychain is locked." } }
    let fleet = ViamOrgFleet(orgID: "o1", tokens: ScriptedTokens(failing: KeychainLocked()), baseURL: StubProtocol.register { _, _ in
        ok(Viam_App_V1_ListLocationsResponse())
    }, session: session)
    await #expect(throws: FleetError.unreachable("The keychain is locked.")) { _ = try await fleet.locations() }
}

@Test func listsOrganizationsByName() async throws {
    let seen = Seen([])
    let client = client(ScriptedTokens(["t1"]), seen: seen) { _ in
        ok(organizations([("o2", "Beta"), ("o1", "acme")]))
    }
    // Case-sensitive order would put "Beta" first.
    #expect(try await client.organizations() == [ViamOrganization(id: "o1", name: "acme"), ViamOrganization(id: "o2", name: "Beta")])
    #expect(seen.withLock { $0.map(\.path) } == ["/viam.app.v1.AppService/ListOrganizations"])
}

@Test func listerMapsRefusalToRejected() async {
    let lister = ViamOrganizationLister(tokens: ScriptedTokens(["t1"]), baseURL: StubProtocol.register { _, _ in
        trailerStatus(7, "no access")
    }, session: session)
    await #expect(throws: FleetError.rejected("no access")) { _ = try await lister.organizations() }
}

// MARK: - API-key sign-in

@Test func authenticateSendsTheKeyAsAnAPIKeyEntity() async throws {
    let body = Locked<Data?>(nil)
    let base = StubProtocol.register { request, data in
        #expect(request.url!.path == "/proto.rpc.v1.AuthService/Authenticate")
        body.withLock { $0 = data }
        return ok(authenticated(token: "access-1"))
    }
    #expect(try await ViamAppClient.authenticate(keyID: "kid", key: "kval", baseURL: base, session: session) == "access-1")
    let request = try unframe(Proto_Rpc_V1_AuthenticateRequest.self, try #require(body.withLock { $0 }))
    #expect(request.entity == "kid")
    #expect(request.credentials.type == "api-key")
    #expect(request.credentials.payload == "kval")
}

@Test(arguments: [3, 5, 7, 16])
func refusedKeyIsAPIKeyRefused(code: Int) async {
    let base = StubProtocol.register { _, _ in trailerStatus(code, "bad key") }
    await #expect(throws: APIKeyRefused()) {
        _ = try await ViamAppClient.authenticate(keyID: "kid", key: "kval", baseURL: base, session: session)
    }
}

/// Viam failing to answer says nothing about the key, so the session isn't signed out.
@Test func unavailableViamIsNotARefusal() async {
    let base = StubProtocol.register { _, _ in trailerStatus(14, "unavailable") }
    await #expect(throws: ViamError.self) {
        _ = try await ViamAppClient.authenticate(keyID: "kid", key: "kval", baseURL: base, session: session)
    }
}

@Test func listerReadsOneOrganization() async throws {
    let lister = ViamOrganizationLister(tokens: ScriptedTokens(["t1"]), baseURL: StubProtocol.register { request, _ in
        #expect(request.url!.path == "/viam.app.v1.AppService/GetOrganization")
        return ok(organization("o1", "Acme"))
    }, session: session)
    #expect(try await lister.organization(id: "o1") == ViamOrganization(id: "o1", name: "Acme"))
}
