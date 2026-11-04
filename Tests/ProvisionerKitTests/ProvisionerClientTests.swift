import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import ProvisionerKit
import Testing

private let base = URL(string: "http://provisioner.local:8235")!

private func utc(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: hour, minute: minute, second: second))!
}

private func sentJSON(_ transport: ScriptedTransport) throws -> Any {
    try JSONSerialization.jsonObject(with: #require(transport.sent.first?.body))
}

/// Fails every request the way URLSession does when nothing listens.
private struct RefusingTransport: ClientTransport {
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        throw URLError(.cannotConnectToHost)
    }
}

@Test func provisionPostsArrayAndMapsResults() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"results":[{"name":"a","result":"added"},{"name":"b","result":"skipped","reason":"already-queued"}]}
        """#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    let results = try await client.provision([ProvisionRequest(name: "a"), ProvisionRequest(name: "b")])

    #expect(results == [
        ProvisionResult(name: "a", added: true, reason: nil),
        ProvisionResult(name: "b", added: false, reason: "already-queued"),
    ])
    #expect(transport.sent.first?.request.method == .post)
    #expect(transport.sent.first?.request.path == "/api/v1/provision")
    let sent = try #require(try sentJSON(transport) as? [[String: Any]])
    #expect(sent.map { $0["name"] as? String } == ["a", "b"])
    #expect(sent.allSatisfy { $0["credentials"] == nil && $0["environment"] == nil }, "absent fields must not be sent: \(sent)")
}

@Test func provisionSendsCredentialsAndEveryEnvironmentField() async throws {
    let transport = ScriptedTransport(json: 200, #"{"results":[{"name":"m1","result":"added"}]}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)
    let environment = EnvironmentConfig(
        provisionMode: .agent, username: "viam", passwordHash: "$6$salt$hash", sshPublicKey: "ssh-ed25519 AAAA",
        timezone: "America/New_York", packages: ["htop", "jq"], wifi: .init(ssid: "lab", password: nil, country: "US"),
        tailscaleAuthKey: "tskey-1")
    let viamJSON = Data(#"{"cloud":{"app_address":"https://app.viam.com:443","id":"part-1","secret":"s3cr3t"}}"#.utf8)

    _ = try await client.provision([ProvisionRequest(name: "m1", credentialsJSON: viamJSON, environment: environment)])

    let item = try #require((try sentJSON(transport) as? [[String: Any]])?.first)
    let env = try #require(item["environment"] as? [String: Any])
    #expect(env["provision_mode"] as? String == "agent")
    #expect(env["username"] as? String == "viam")
    #expect(env["password_hash"] as? String == "$6$salt$hash")
    #expect(env["ssh_public_key"] as? String == "ssh-ed25519 AAAA")
    #expect(env["timezone"] as? String == "America/New_York")
    #expect(env["packages"] as? [String] == ["htop", "jq"])
    #expect(env["tailscale_auth_key"] as? String == "tskey-1")
    #expect(env["wifi"] as? [String: String] == ["ssid": "lab", "country": "US"])
    let cloud = try #require((item["credentials"] as? [String: Any])?["cloud"] as? [String: String])
    #expect(cloud == ["app_address": "https://app.viam.com:443", "id": "part-1", "secret": "s3cr3t"])
}

@Test func osOnlyModeIsSentWithItsHyphen() async throws {
    let transport = ScriptedTransport(json: 200, #"{"results":[{"name":"m1","result":"added"}]}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)
    let environment = EnvironmentConfig(
        provisionMode: .osOnly, username: "viam", passwordHash: "h", sshPublicKey: "k", timezone: "UTC")

    _ = try await client.provision([ProvisionRequest(name: "m1", environment: environment)])

    let item = try #require((try sentJSON(transport) as? [[String: Any]])?.first)
    #expect((item["environment"] as? [String: Any])?["provision_mode"] as? String == "os-only")
}

@Test func queueMapsSnapshotAndSpecTimestamps() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"last_event_id":7,"entries":[
          {"name":"m1","status":"assigned","mac":"aa:bb:cc:dd:ee:ff","has_credentials":true,"assigned_at":"2026-10-04T04:08:29+00:00"},
          {"name":"m2","status":"queued","has_credentials":false,"assigned_at":"2026-10-04T00:08:29-04:00"}]}
        """#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    let snapshot = try await client.queue()

    #expect(snapshot == QueueSnapshot(entries: [
        QueueEntry(name: "m1", status: .assigned, mac: "aa:bb:cc:dd:ee:ff", assignedAt: utc(4, 8, 29), hasCredentials: true),
        QueueEntry(name: "m2", status: .queued, assignedAt: utc(4, 8, 29), hasCredentials: false),
    ], lastEventID: 7))
}

@Test func entryReadsItsNamedPath() async throws {
    let transport = ScriptedTransport(json: 200, #"{"name":"m1","status":"installing","has_credentials":false,"stage":"late-commands"}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    let entry = try await client.entry(named: "m1")

    #expect(entry == QueueEntry(name: "m1", status: .installing, stage: "late-commands", hasCredentials: false))
    #expect(transport.sent.first?.request.method == .get)
    #expect(transport.sent.first?.request.path == "/api/v1/queue/m1")
}

@Test func missingEntryIsNotFound() async {
    let transport = ScriptedTransport(json: 404, #"{"error":{"code":"not-found","message":"no m9"}}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.server(status: 404, code: "not-found", message: "no m9", details: [])) {
        try await client.entry(named: "m9")
    }
}

@Test func removeDeletesOnNoContent() async throws {
    let transport = ScriptedTransport([(204, "application/json", "")])
    let client = ProvisionerClient(baseURL: base, transport: transport)

    try await client.remove(named: "m1")

    #expect(transport.sent.first?.request.method == .delete)
    #expect(transport.sent.first?.request.path == "/api/v1/queue/m1")
}

@Test func assignedRemoveIsServerError() async {
    let transport = ScriptedTransport(json: 409, #"{"error":{"code":"already-assigned","message":"m1 is installing"}}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.server(status: 409, code: "already-assigned", message: "m1 is installing", details: [])) {
        try await client.remove(named: "m1")
    }
}

@Test func validationDetailsAreKept() async {
    let transport = ScriptedTransport(json: 400, #"""
        {"error":{"code":"invalid-request","message":"bad items","details":[{"index":1,"field":"name","message":"invalid"}]}}
        """#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.server(
        status: 400, code: "invalid-request", message: "bad items",
        details: [.init(index: 1, field: "name", message: "invalid")])) {
        try await client.provision([ProvisionRequest(name: "m1"), ProvisionRequest(name: "m2")])
    }
}

@Test func statusMapsEveryField() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"api_version":"v1","server_name":"lab-mac","time":"2026-10-04T04:08:29+00:00","address":"10.0.0.2:8234",
         "queue":{"queued":1,"flashed":2,"assigned":3,"installing":4,"installed":5,"failed":6,"total":21},
         "services":{"http":"up","dnsmasq":"down","watcher":"unknown"},"last_event_id":9}
        """#)
    let status = try await ProvisionerClient(baseURL: base, transport: transport).status()

    #expect(status.apiVersion == "v1")
    #expect(status.serverName == "lab-mac")
    #expect(status.time == utc(4, 8, 29))
    #expect(status.address == "10.0.0.2:8234")
    #expect(status.queue == .init(queued: 1, flashed: 2, assigned: 3, installing: 4, installed: 5, failed: 6, total: 21))
    #expect(status.services == .init(http: .up, dnsmasq: .down, watcher: .unknown))
    #expect(status.lastEventID == 9)
}

@Test func statusWithoutQueueOrAddress() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"api_version":"v1","server_name":"lab-mac","time":"2026-10-04T04:08:29+00:00",
         "services":{"http":"up","dnsmasq":"up","watcher":"up"},"last_event_id":0}
        """#)
    let status = try await ProvisionerClient(baseURL: base, transport: transport).status()

    #expect(status.queue == nil)
    #expect(status.address == nil)
}

@Test func statusWithoutPythonServices() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"api_version":"v1","server_name":"lab-mac","time":"2026-10-04T04:08:29+00:00",
         "services":{"http":"up"},"last_event_id":0}
        """#)
    let status = try await ProvisionerClient(baseURL: base, transport: transport).status()

    #expect(status.services == .init(http: .up))
}

@Test func statusWithHelper() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"api_version":"v1","server_name":"lab-mac","time":"2026-10-04T04:08:29+00:00",
         "services":{"http":"up","helper":"down"},"last_event_id":0}
        """#)
    let status = try await ProvisionerClient(baseURL: base, transport: transport).status()

    #expect(status.services.helper == .down)
}

@Test func htmlBadGatewayIsUnexpected() async {
    let transport = ScriptedTransport([(502, "text/html", "<html><body>502 Bad Gateway</body></html>")])
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.unexpectedResponse(status: 502)) {
        try await client.queue()
    }
}

@Test func unreachableServerIsTransportError() async {
    let client = ProvisionerClient(baseURL: base, transport: RefusingTransport())

    await #expect(throws: ProvisionerError.transport(URLError(.cannotConnectToHost))) {
        try await client.status()
    }
}

@Test func eventFramesSendsLastEventID() async throws {
    let frame = """
        retry: 3000

        id: 13
        event: machine-assigned
        data: {"id":13,"type":"machine-assigned","timestamp":"2026-10-04T04:08:29+00:00","name":"m1","mac":"aa:bb:cc:dd:ee:ff"}


        """
    let transport = ScriptedTransport([(200, "text/event-stream", frame)])
    let client = ProvisionerClient(baseURL: base, transport: transport)

    var ids: [String?] = []
    for try await event in try await client.eventFrames(after: 12) where event.data != nil {
        ids.append(event.id)
    }

    #expect(transport.sent.first?.request.path == "/api/v1/events")
    #expect(transport.sent.first?.request.headerFields[.init("Last-Event-ID")!] == "12")
    #expect(ids == ["13"])
}

@Test func tooManyStreamsIsServerError() async {
    let transport = ScriptedTransport(json: 503, #"{"error":{"code":"too-many-streams","message":"limit 16"}}"#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.server(status: 503, code: "too-many-streams", message: "limit 16", details: [])) {
        _ = try await client.eventFrames(after: 0)
    }
}
