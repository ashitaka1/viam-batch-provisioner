import Foundation
@testable import ProvisionerKit
import Testing

private let base = URL(string: "http://provisioner.local:8235")!

@Test func provisionSendsArrayAndMapsResults() async throws {
    let transport = ScriptedTransport(json: 200, #"""
        {"results":[{"name":"a","result":"added"},{"name":"b","result":"skipped","reason":"already-queued"}]}
        """#)
    let client = ProvisionerClient(baseURL: base, transport: transport)

    let results = try await client.provision([ProvisionRequest(name: "a"), ProvisionRequest(name: "b")])

    #expect(results == [
        ProvisionResult(name: "a", added: true, reason: nil),
        ProvisionResult(name: "b", added: false, reason: "already-queued"),
    ])
    let sentBody = try #require(transport.sent.first?.body)
    let sent = try #require(JSONSerialization.jsonObject(with: sentBody) as? [[String: Any]])
    #expect(sent.map { $0["name"] as? String } == ["a", "b"])
}

@Test func documentedErrorBecomesServerError() async {
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
        try await client.provision([ProvisionRequest(name: "ok"), ProvisionRequest(name: "Bad")])
    }
}

@Test func htmlBadGatewayIsUnexpected() async {
    let transport = ScriptedTransport([(502, "text/html", "<html><body>502 Bad Gateway</body></html>")])
    let client = ProvisionerClient(baseURL: base, transport: transport)

    await #expect(throws: ProvisionerError.unexpectedResponse(status: 502)) {
        try await client.queue()
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

    #expect(transport.sent.first?.request.headerFields[.init("Last-Event-ID")!] == "12")
    #expect(ids == ["13"])
}
