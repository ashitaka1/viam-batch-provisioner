import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI

private typealias Seen = Locked<[(path: String, body: Data, authorization: String?)]>

/// A fleet whose AppService calls go to `reply`, recording each request in `seen`.
/// Authenticate answers with `authenticate`, which succeeds unless a test overrides it.
private func fleet(
    seen: Seen = Seen([]),
    authenticate: @escaping () -> StubProtocol.Reply = { ok(authenticated()) },
    _ reply: @escaping (String) -> StubProtocol.Reply
) -> ViamOrgFleet {
    let base = StubProtocol.register { request, body in
        let path = request.url!.path
        seen.withLock { $0.append((path, body, request.value(forHTTPHeaderField: "authorization"))) }
        return path.hasSuffix("Authenticate") ? authenticate() : reply(path)
    }
    return ViamOrgFleet(credential: credential, baseURL: base, session: session)
}

private func lastCall(_ seen: Seen) throws -> (path: String, body: Data, authorization: String?) {
    try #require(seen.withLock { $0.last })
}

private func part(_ id: String, secret: String = "", main: Bool) -> Viam_App_V1_RobotPart {
    var part = Viam_App_V1_RobotPart()
    part.id = id
    part.secret = secret
    part.mainPart = main
    return part
}

private func describe(_ error: FleetError?) -> String { error.map { "\($0)" } ?? "no error" }

@Test func listsLocationsForTheCredentialsOrg() async throws {
    let seen = Seen([])
    let fleet = fleet(seen: seen) { _ in
        var response = Viam_App_V1_ListLocationsResponse()
        response.locations = [("l1", "Bench"), ("l2", "Shop")].map { id, name in
            var location = Viam_App_V1_Location()
            location.id = id
            location.name = name
            return location
        }
        return ok(response)
    }
    #expect(try await fleet.locations() == [ViamLocation(id: "l1", name: "Bench"), ViamLocation(id: "l2", name: "Shop")])

    let call = try lastCall(seen)
    #expect(call.path == "/viam.app.v1.AppService/ListLocations")
    #expect(try unframe(Viam_App_V1_ListLocationsRequest.self, call.body).organizationID == "o1")
}

@Test func listsMachinesInLocation() async throws {
    let seen = Seen([])
    let fleet = fleet(seen: seen) { _ in
        var robot = Viam_App_V1_Robot()
        robot.id = "m1"
        robot.name = "lab-pi-1"
        var response = Viam_App_V1_ListRobotsResponse()
        response.robots = [robot]
        return ok(response)
    }
    #expect(try await fleet.machines(location: "l1") == [ViamMachine(id: "m1", name: "lab-pi-1")])

    let call = try lastCall(seen)
    #expect(call.path == "/viam.app.v1.AppService/ListRobots")
    #expect(try unframe(Viam_App_V1_ListRobotsRequest.self, call.body).locationID == "l1")
}

@Test func createsMachineInLocation() async throws {
    let seen = Seen([])
    let fleet = fleet(seen: seen) { _ in
        var response = Viam_App_V1_NewRobotResponse()
        response.id = "m1"
        return ok(response)
    }
    #expect(try await fleet.createMachine(name: "lab-pi-1", location: "l1") == "m1")

    let call = try lastCall(seen)
    #expect(call.path == "/viam.app.v1.AppService/NewRobot")
    let request = try unframe(Viam_App_V1_NewRobotRequest.self, call.body)
    #expect(request.name == "lab-pi-1" && request.location == "l1")
    #expect(call.authorization == "Bearer tok")
}

@Test func picksTheMainPart() async throws {
    let seen = Seen([])
    let fleet = fleet(seen: seen) { _ in
        var response = Viam_App_V1_GetRobotPartsResponse()
        response.parts = [part("p0", main: false), part("p1", secret: "s1", main: true)]
        return ok(response)
    }
    #expect(try await fleet.mainPart(machine: "m1") == MachinePart(id: "p1", secret: "s1"))

    let call = try lastCall(seen)
    #expect(call.path == "/viam.app.v1.AppService/GetRobotParts")
    #expect(try unframe(Viam_App_V1_GetRobotPartsRequest.self, call.body).robotID == "m1")
}

@Test func noMainPartFails() async {
    let fleet = fleet { _ in ok(Viam_App_V1_GetRobotPartsResponse()) }
    await #expect(throws: FleetError.failed("Machine m1 has no main part.")) { try await fleet.mainPart(machine: "m1") }
}

@Test func deletesMachineByID() async throws {
    let seen = Seen([])
    let fleet = fleet(seen: seen) { _ in ok(Viam_App_V1_DeleteRobotResponse()) }
    try await fleet.deleteMachine(id: "m1")

    let call = try lastCall(seen)
    #expect(call.path == "/viam.app.v1.AppService/DeleteRobot")
    #expect(try unframe(Viam_App_V1_DeleteRobotRequest.self, call.body).id == "m1")
}

/// Viam's message is kept, so a name it refuses is explained in its own words.
@Test(arguments: [
    (16, FleetError.rejected("refused")),
    (7, .rejected("refused")),
    (14, .unreachable("refused")),
    (4, .unreachable("refused")),
    (3, .failed("refused")),
])
func mapsStatuses(code: Int, expected: FleetError) async {
    let fleet = fleet { _ in trailerStatus(code, "refused") }
    await #expect(throws: expected) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
}

/// A revoked key fails at Authenticate; that must stop the batch like any other refusal.
@Test func refusedAuthenticationIsRejection() async {
    let fleet = fleet(authenticate: { trailerStatus(16, "key revoked") }) { _ in ok(Viam_App_V1_NewRobotResponse()) }
    await #expect(throws: FleetError.rejected("key revoked")) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
}

@Test func transportFailureIsUnreachable() async {
    let base = StubProtocol.register { _, _ in StubProtocol.Reply(error: URLError(.timedOut)) }
    let fleet = ViamOrgFleet(credential: credential, baseURL: base, session: session)
    let thrown = await #expect(throws: FleetError.self) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
    let isUnreachable = if case .unreachable? = thrown { true } else { false }
    #expect(isUnreachable, "expected .unreachable, got \(describe(thrown))")
}

@Test func unreadableResponseIsUnreachable() async {
    let fleet = fleet { _ in StubProtocol.Reply(body: Data([0, 0, 0])) }
    let thrown = await #expect(throws: FleetError.self) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
    let isUnreachable = if case .unreachable? = thrown { true } else { false }
    #expect(isUnreachable, "an unreadable reply leaves the outcome unknown; got \(describe(thrown))")
}
