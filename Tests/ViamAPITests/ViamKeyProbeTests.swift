import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI

private func getLocation(_ id: String, _ name: String, orgs: [String]) -> Viam_App_V1_GetLocationResponse {
    var response = Viam_App_V1_GetLocationResponse()
    response.location.id = id
    response.location.name = name
    response.location.organizations = orgs.map {
        var org = Viam_App_V1_LocationOrganization()
        org.organizationID = $0
        return org
    }
    return response
}

/// A probe whose Authenticate answers with a token and whose AppService calls get `reply`.
private func probe(_ reply: @escaping @Sendable (URLRequest, Data) -> StubProtocol.Reply) -> ViamKeyProbe {
    ViamKeyProbe(keyID: "kid", key: "kval", baseURL: StubProtocol.register { request, body in
        request.url!.path.hasSuffix("Authenticate") ? ok(authenticated()) : reply(request, body)
    }, session: session)
}

@Test func probeReadsALocationWithItsOrgs() async throws {
    let probe = probe { request, body in
        #expect(request.url!.path == "/viam.app.v1.AppService/GetLocation")
        #expect((try? unframe(Viam_App_V1_GetLocationRequest.self, body).locationID) == "l1")
        return ok(getLocation("l1", "Shop floor", orgs: ["o1"]))
    }
    let found = try await probe.location(id: "l1")
    #expect(found.location == ViamLocation(id: "l1", name: "Shop floor"))
    #expect(found.orgIDs == ["o1"])
}

@Test func probeReadsOneOrganization() async throws {
    let probe = probe { request, _ in
        #expect(request.url!.path == "/viam.app.v1.AppService/GetOrganization")
        return ok(organization("o1", "Acme"))
    }
    #expect(try await probe.organization(id: "o1") == ViamOrganization(id: "o1", name: "Acme"))
}

@Test func probeMapsARefusedListToRejected() async {
    let probe = probe { _, _ in trailerStatus(7, "no access") }
    await #expect(throws: FleetError.rejected("no access")) { _ = try await probe.organizations() }
}

@Test func probeAuthenticateMapsARefusedKeyToRejected() async {
    let probe = ViamKeyProbe(keyID: "kid", key: "kval", baseURL: StubProtocol.register { _, _ in trailerStatus(16, "bad key") },
                             session: session)
    await #expect(throws: KeyCheckError.rejected) { try await probe.authenticate() }
}

@Test func probeAuthenticateMapsUnavailableToUnreachable() async {
    let probe = ViamKeyProbe(keyID: "kid", key: "kval", baseURL: StubProtocol.register { _, _ in trailerStatus(14, "down") },
                             session: session)
    do {
        try await probe.authenticate()
        Issue.record("an unavailable Viam authenticated")
    } catch {
        guard case .unreachable = error else { Issue.record("expected unreachable, got \(error)"); return }
    }
}

@Test func probeNamesALocationsPrimaryOrgFirst() async throws {
    var response = getLocation("l1", "Shop floor", orgs: ["o-shared", "o-owner"])
    response.location.organizations[1].primary = true
    let reply = response
    let probe = probe { _, _ in ok(reply) }
    #expect(try await probe.location(id: "l1").orgIDs == ["o-owner", "o-shared"])
}
