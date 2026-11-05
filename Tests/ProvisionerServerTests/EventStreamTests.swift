import AsyncHTTPClient
import Foundation
import NIOCore
import ProvisionerAPI
@testable import ProvisionerKit
@testable import ProvisionerServer
import ServiceLifecycleTestKit
import Testing

private struct Timeout: Error {}

/// Reads the event stream at `query` until `done` holds for the text so far, or 5 seconds pass.
private func readEvents(port: Int, query: String = "", lastEventID: Int? = nil,
                        until done: @escaping @Sendable (String) -> Bool) async throws -> String {
    var request = HTTPClientRequest(url: "http://localhost:\(port)/api/v1/events\(query)")
    if let lastEventID { request.headers.add(name: "Last-Event-ID", value: "\(lastEventID)") }
    let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
    #expect(response.status.code == 200)
    return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            var text = ""
            for try await chunk in response.body {
                text += String(buffer: chunk)
                if done(text) { return text }
            }
            return text
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw Timeout()
        }
        let text = try await group.next()!
        group.cancelAll()
        return text
    }
}

/// Reports three progress stages for m-1, producing events 1 to 3.
private func threeEvents(_ client: ProvisionerClient, _ port: Int) async throws {
    _ = try await client.provision([ProvisionRequest(name: "m-1")])
    for stage in ["late-commands", "identity", "tooling"] {
        var request = HTTPClientRequest(url: "http://localhost:\(port)/api/v1/install-reports")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(string: #"{"kind":"progress","stage":"\#(stage)","name":"m-1"}"#))
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
        #expect(response.status.code == 200)
    }
}

private func ids(_ text: String) -> [String] {
    text.split(separator: "\n").filter { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
}

@Test func queueFeedSeesSnapshotThenEvents() async throws {
    try await withLiveServer { client, test, _ in
        _ = try await client.provision([ProvisionRequest(name: "m-1")])
        var updates = QueueFeed(source: client).updates().makeAsyncIterator()

        guard case .snapshot(let entries) = await updates.next() else {
            Issue.record("expected a snapshot first")
            return
        }
        #expect(entries.map(\.name) == ["m-1"])

        var request = HTTPClientRequest(url: "http://localhost:\(test.port!)/api/v1/install-reports")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(string: #"{"kind":"progress","stage":"late-commands","name":"m-1"}"#))
        _ = try await HTTPClient.shared.execute(request, timeout: .seconds(5))

        guard case .event(let event, let inSnapshot) = await updates.next() else {
            Issue.record("expected an event after the snapshot")
            return
        }
        #expect(event.kind == .installProgress(stage: "late-commands"))
        #expect(event.name == "m-1")
        #expect(!inSnapshot)
    }
}

@Test func replayFromLastEventID() async throws {
    try await withLiveServer { client, test, _ in
        try await threeEvents(client, test.port!)

        let text = try await readEvents(port: test.port!, lastEventID: 1) { ids($0).count >= 2 }

        #expect(text.hasPrefix("retry: 3000\n\n"))
        #expect(ids(text) == ["2", "3"])
        #expect(text.contains("event: install-progress\n"))
    }
}

@Test func queryCursorFallback() async throws {
    try await withLiveServer { client, test, _ in
        try await threeEvents(client, test.port!)

        let text = try await readEvents(port: test.port!, query: "?last_event_id=2") { ids($0).count >= 1 }

        #expect(ids(text) == ["3"])
    }
}

@Test func aheadGetsResync() async throws {
    try await withLiveServer { client, test, _ in
        try await threeEvents(client, test.port!)

        let text = try await readEvents(port: test.port!, lastEventID: 50) { $0.contains("latest_id") }

        let frames = text.components(separatedBy: "\n\n")
        #expect(frames[1].hasPrefix("event: resync\ndata: "))
        #expect(frames[1].contains(#""latest_id":3"#))
        #expect(!frames[1].contains("id: "))
    }
}

@Test func keepaliveAfterSilence() async throws {
    try await withLiveServer(streamOptions: .init(keepalive: .milliseconds(100))) { _, test, _ in
        let text = try await readEvents(port: test.port!) { $0.contains(": keepalive\n\n") }

        #expect(text.contains(": keepalive\n\n"))
    }
}

@Test func streamLimit() async throws {
    try await withLiveServer(streamOptions: .init(limit: 2)) { _, test, _ in
        let first = try await openStream(port: test.port!)
        let second = try await openStream(port: test.port!)

        let response = try await HTTPClient.shared.execute(
            HTTPClientRequest(url: "http://localhost:\(test.port!)/api/v1/events"), timeout: .seconds(5))
        let body = try await response.body.collect(upTo: 1 << 16)

        #expect(response.status.code == 503)
        #expect(try JSONDecoder().decode(Schemas._Error.self, from: Data(buffer: body)).error.code == .tooManyStreams)
        withExtendedLifetime((first, second)) {}
    }
}

/// The server learns of a disconnect when it next writes, so a short keepalive
/// stands in for the 15-second default. Five streams in turn through two slots.
@Test func closedStreamsFreeSlots() async throws {
    try await withLiveServer(streamOptions: .init(keepalive: .milliseconds(100), limit: 2)) { _, test, _ in
        for round in 0..<5 {
            let status = try await pollStatus(port: test.port!, until: { $0 == 200 }, within: .seconds(2))
            #expect(status == 200, "stream \(round + 1) of 5")
        }
    }
}

/// An open stream whose `retry` frame has arrived, so the server holds its slot.
private func openStream(port: Int) async throws -> (HTTPClientResponse, HTTPClientResponse.Body.AsyncIterator) {
    let response = try await HTTPClient.shared.execute(
        HTTPClientRequest(url: "http://localhost:\(port)/api/v1/events"), timeout: .seconds(5))
    #expect(response.status.code == 200)
    var iterator = response.body.makeAsyncIterator()
    _ = try await iterator.next()
    return (response, iterator)
}

/// Polls `GET /api/v1/events` until its status satisfies `until`, closing each stream it opens.
private func pollStatus(port: Int, until: (UInt) -> Bool, within limit: Duration) async throws -> UInt {
    let deadline = ContinuousClock.now + limit
    var status: UInt = 0
    repeat {
        let response = try await HTTPClient.shared.execute(
            HTTPClientRequest(url: "http://localhost:\(port)/api/v1/events"), timeout: .seconds(5))
        status = response.status.code
        if status == 200 {
            var iterator = response.body.makeAsyncIterator()
            _ = try await iterator.next()
        } else {
            _ = try await response.body.collect(upTo: 1 << 16)
        }
        if until(status) { return status }
        try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
    return status
}


@Test func gracefulShutdownEndsStream() async throws {
    try await testGracefulShutdown { trigger in
        let (provisioner, _) = try makeProvisioner()
        let released = TestFlag()
        let body = sseBody(await provisioner.subscribe(after: nil), keepalive: .seconds(60)) { released.set() }
        var frames = body.makeAsyncIterator()
        _ = try await frames.next()

        trigger.triggerGracefulShutdown()

        #expect(try await frames.next() == nil)
        try await poll(within: .seconds(2)) { released.isSet }
        #expect(released.isSet)
    }
}
