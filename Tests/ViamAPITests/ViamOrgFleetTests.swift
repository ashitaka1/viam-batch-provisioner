import Foundation
import ProvisionerKit
import SwiftProtobuf
import Testing
@testable import ViamAPI

/// A fleet whose AppService calls go to `reply`; Authenticate always succeeds.
private func fleet(
    seen: Locked<[(path: String, body: Data, authorization: String?)]> = Locked([]),
    _ reply: @escaping (String, Data) -> StubProtocol.Reply
) -> ViamOrgFleet {
    let base = StubProtocol.register { request, body in
        let path = request.url!.path
        seen.withLock { $0.append((path, body, request.value(forHTTPHeaderField: "authorization"))) }
        return path.hasSuffix("Authenticate") ? ok(authenticated()) : reply(path, body)
    }
    return ViamOrgFleet(credential: credential, baseURL: base, session: session)
}

private func part(_ id: String, secret: String = "", main: Bool) -> Viam_App_V1_RobotPart {
    var part = Viam_App_V1_RobotPart()
    part.id = id
    part.secret = secret
    part.mainPart = main
    return part
}

@Test func listsLocationsForTheCredentialsOrg() async throws {
    let fleet = fleet { path, body in
        #expect(path == "/viam.app.v1.AppService/ListLocations")
        #expect((try? unframe(Viam_App_V1_ListLocationsRequest.self, body))?.organizationID == "o1")
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
}

@Test func listsMachinesInLocation() async throws {
    let fleet = fleet { path, body in
        #expect(path == "/viam.app.v1.AppService/ListRobots")
        #expect((try? unframe(Viam_App_V1_ListRobotsRequest.self, body))?.locationID == "l1")
        var robot = Viam_App_V1_Robot()
        robot.id = "m1"
        robot.name = "lab-pi-1"
        var response = Viam_App_V1_ListRobotsResponse()
        response.robots = [robot]
        return ok(response)
    }
    #expect(try await fleet.machines(location: "l1") == [ViamMachine(id: "m1", name: "lab-pi-1")])
}

@Test func createsMachineInLocation() async throws {
    let seen = Locked<[(path: String, body: Data, authorization: String?)]>([])
    let fleet = fleet(seen: seen) { _, _ in
        var response = Viam_App_V1_NewRobotResponse()
        response.id = "m1"
        return ok(response)
    }
    #expect(try await fleet.createMachine(name: "lab-pi-1", location: "l1") == "m1")

    let call = try #require(seen.withLock { $0.last })
    #expect(call.path == "/viam.app.v1.AppService/NewRobot")
    let request = try unframe(Viam_App_V1_NewRobotRequest.self, call.body)
    #expect(request.name == "lab-pi-1" && request.location == "l1")
    #expect(call.authorization == "Bearer tok")
}

@Test func picksTheMainPart() async throws {
    let fleet = fleet { path, body in
        #expect(path == "/viam.app.v1.AppService/GetRobotParts")
        #expect((try? unframe(Viam_App_V1_GetRobotPartsRequest.self, body))?.robotID == "m1")
        var response = Viam_App_V1_GetRobotPartsResponse()
        response.parts = [part("p0", main: false), part("p1", secret: "s1", main: true)]
        return ok(response)
    }
    #expect(try await fleet.mainPart(machine: "m1") == MachinePart(id: "p1", secret: "s1"))
}

@Test func noMainPartFails() async {
    let fleet = fleet { _, _ in ok(Viam_App_V1_GetRobotPartsResponse()) }
    await #expect(throws: FleetError.failed("Machine m1 has no main part.")) { try await fleet.mainPart(machine: "m1") }
}

@Test func deletesMachineByID() async throws {
    let seen = Locked<[(path: String, body: Data, authorization: String?)]>([])
    let fleet = fleet(seen: seen) { _, _ in ok(Viam_App_V1_DeleteRobotResponse()) }
    try await fleet.deleteMachine(id: "m1")

    let call = try #require(seen.withLock { $0.last })
    #expect(call.path == "/viam.app.v1.AppService/DeleteRobot")
    #expect(try unframe(Viam_App_V1_DeleteRobotRequest.self, call.body).id == "m1")
}

@Test(arguments: [
    (16, FleetError.rejected("refused")),
    (7, .rejected("refused")),
    (14, .unreachable("refused")),
    (4, .unreachable("refused")),
    (3, .failed("refused")),
])
func mapsStatuses(code: Int, expected: FleetError) async {
    let fleet = fleet { _, _ in trailerStatus(code, "refused") }
    await #expect(throws: expected) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
}

/// Viam's own words reach the operator when it refuses a name.
@Test func passesViamsNameRejectionThrough() async {
    let message = "Machine name cannot start with a dash"
    let fleet = fleet { _, _ in trailerStatus(3, message) }
    await #expect(throws: FleetError.failed(message)) { _ = try await fleet.createMachine(name: "-x", location: "l1") }
}

@Test func transportFailureIsUnreachable() async {
    let base = StubProtocol.register { _, _ in StubProtocol.Reply(error: URLError(.timedOut)) }
    let fleet = ViamOrgFleet(credential: credential, baseURL: base, session: session)
    let thrown = await #expect(throws: FleetError.self) { _ = try await fleet.createMachine(name: "lab-pi-1", location: "l1") }
    guard case .unreachable? = thrown else {
        Issue.record("expected .unreachable, got \(String(describing: thrown))")
        return
    }
}

@Test func authenticatesOnce() async throws {
    let seen = Locked<[(path: String, body: Data, authorization: String?)]>([])
    let fleet = fleet(seen: seen) { _, _ in ok(Viam_App_V1_ListRobotsResponse()) }
    for _ in 0..<3 { _ = try await fleet.machines(location: "l1") }
    #expect(seen.withLock { $0.filter { $0.path.hasSuffix("Authenticate") }.count } == 1)
}
