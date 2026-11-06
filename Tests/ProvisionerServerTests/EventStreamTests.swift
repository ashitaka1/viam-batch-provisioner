import AsyncHTTPClient
import Foundation
import NIOCore
import ProvisionerAPI
@testable import ProvisionerKit
@testable import ProvisionerServer
import ServiceLifecycleTestKit
import Testing

private struct StreamTimedOut: Error, CustomStringConvertible {
    let received: String
    var description: String { "no matching frames within 5 s; received: \(received.debugDescription)" }
}

/// Reads the event stream at `query` until `done` holds for the text so far, or 5 seconds pass.
private func readEvents(port: Int, query: String = "", lastEventID: Int? = nil,
                        until done: @escaping @Sendable (String) -> Bool) async throws -> String {
    var request = HTTPClientRequest(url: "http://localhost:\(port)/api/v1/events\(query)")
    if let lastEventID { request.headers.add(name: "Last-Event-ID", value: "\(lastEventID)") }
    let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
    #expect(response.status.code == 200)
    let received = TextBox()
    return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            for try await chunk in response.body {
                received.append(String(buffer: chunk))
                if done(received.text) { return received.text }
            }
            return received.text
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw StreamTimedOut(received: received.text)
        }
        let text = try await group.next()!
        group.cancelAll()
        return text
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.withLock { value } }
    func append(_ more: String) { lock.withLock { value += more } }
}

/// Reports three progress stages for m-1, producing events 1 to 3.
private func threeEvents(_ client: ProvisionerClient, _ port: Int) async throws {
    _ = try await client.provision([ProvisionRequest(name: "m-1")])
    for stage in ["late-commands", "identity", "tooling"] {
        #expect(try await postReport(port: port, #"{"kind":"progress","stage":"\#(stage)","name":"m-1"}"#) == 200)
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

        try await postReport(port: test.port!, #"{"kind":"progress","stage":"late-commands","name":"m-1"}"#)

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
        let body = sseBody(await provisioner.subscribe(after: nil), keepalive: .seconds(60), buffer: 16) { released.set() }
        var frames = body.makeAsyncIterator()
        _ = try await frames.next()

        trigger.triggerGracefulShutdown()

        #expect(try await frames.next() == nil)
        try await poll(within: .seconds(2)) { released.isSet }
        #expect(released.isSet, "release not called within 2 s of graceful shutdown")
    }
}

@Test func headerCursorWinsOverQuery() async throws {
    try await withLiveServer { client, test, _ in
        try await threeEvents(client, test.port!)

        let text = try await readEvents(port: test.port!, query: "?last_event_id=0", lastEventID: 2) { ids($0).count >= 1 }

        #expect(ids(text) == ["3"])
    }
}

@Test func negativeCursorRejected() async throws {
    try await withLiveServer { _, test, _ in
        var request = HTTPClientRequest(url: "http://localhost:\(test.port!)/api/v1/events")
        request.headers.add(name: "Last-Event-ID", value: "-1")
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
        let body = try await response.body.collect(upTo: 1 << 16)

        #expect(response.status.code == 400)
        #expect(try JSONDecoder().decode(Schemas._Error.self, from: Data(buffer: body)).error.code == .invalidRequest)
    }
}

@Test func failureAndCompletionFramesNameTheirType() async throws {
    try await withLiveServer { client, test, _ in
        _ = try await client.provision([ProvisionRequest(name: "m-1"), ProvisionRequest(name: "m-2")])
        try await postReport(port: test.port!, #"{"kind":"progress","stage":"done","name":"m-1"}"#)
        try await postReport(port: test.port!, #"{"kind":"failed","stage":"tooling","name":"m-2"}"#)

        let text = try await readEvents(port: test.port!, lastEventID: 0) { ids($0).count >= 3 }

        let names = text.split(separator: "\n").filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) }
        #expect(names == ["install-progress", "install-complete", "install-failed"])
    }
}

private struct StreamDidNotEnd: Error {}

/// Every frame of `body`, which must end within two seconds.
private func drain(_ body: HTTPBody) async throws -> [ArraySlice<UInt8>] {
    try await withThrowingTaskGroup(of: [ArraySlice<UInt8>].self) { group in
        group.addTask {
            var frames: [ArraySlice<UInt8>] = []
            for try await frame in body { frames.append(frame) }
            return frames
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw StreamDidNotEnd()
        }
        let frames = try await group.next()!
        group.cancelAll()
        return frames
    }
}

/// The `id:` lines in the frames read so far.
private func frameIDs(_ frames: [ArraySlice<UInt8>]) -> [String] {
    ids(frames.map { String(decoding: $0, as: UTF8.self) }.joined())
}

@Test func backlogLargerThanTheBufferIsSentWhole() async throws {
    let (provisioner, _) = try makeProvisioner()
    _ = try await provisioner.provision([request("m-1")])
    for stage in Array(repeating: [Schemas.InstallStage.lateCommands, .identity], count: 5).joined() {
        _ = try await provisioner.report(report(.progress, stage, name: "m-1"))
    }
    let released = TestFlag()

    let body = sseBody(await provisioner.subscribe(after: 0), keepalive: .seconds(60), buffer: 4) { released.set() }

    var frames: [ArraySlice<UInt8>] = []
    var iterator = body.makeAsyncIterator()
    for _ in 0..<11 { frames.append(try #require(try await iterator.next())) }
    #expect(frameIDs(frames) == (1...10).map(String.init))
    #expect(!released.isSet, "the backlog alone overflowed the buffer")
}

@Test func stalledClientIsDroppedOnceItsBufferFills() async throws {
    let (provisioner, _) = try makeProvisioner()
    _ = try await provisioner.provision([request("m-1")])
    let released = TestFlag()
    let body = sseBody(await provisioner.subscribe(after: nil), keepalive: .seconds(60), buffer: 4) { released.set() }

    for stage in Array(repeating: [Schemas.InstallStage.lateCommands, .identity], count: 5).joined() {
        _ = try await provisioner.report(report(.progress, stage, name: "m-1"))
    }
    try await poll(within: .seconds(2)) { released.isSet }

    let frames = try await drain(body)
    #expect(released.isSet, "a stalled stream still holds its slot")
    #expect(frameIDs(frames) == ["1", "2", "3", "4"], "the client resumes after the last id it received")
}

/// The ordering race this once guarded (a stream ending before its termination
/// handler was set) doesn't reproduce on demand; the handler is now installed
/// before the tasks that can end the stream start.
@Test func endedSubscriptionEndsTheStreamAndReleasesItsSlot() async throws {
    let (live, continuation) = AsyncStream.makeStream(of: Schemas.MachineEvent.self)
    continuation.finish()
    let cancelled = TestFlag()
    let released = TestFlag()
    let subscription = EventSubscription(backlog: .events([]), live: live, cancel: { cancelled.set() })

    let body = sseBody(subscription, keepalive: .seconds(60), buffer: 4) { released.set() }
    _ = try await drain(body)

    #expect(released.isSet)
    #expect(cancelled.isSet)
}

/// Events every 100 ms on a 1 s keepalive leave no interval silent. The stream
/// opens first, so the events arrive live across two keepalive intervals.
@Test func eventsSuppressKeepalive() async throws {
    try await withLiveServer(streamOptions: .init(keepalive: .seconds(1))) { client, test, _ in
        _ = try await client.provision([ProvisionRequest(name: "m-1")])
        let reporter = Task {
            try await Task.sleep(for: .milliseconds(100))
            for stage in Array(repeating: ["late-commands", "identity"], count: 12).joined() {
                try await postReport(port: test.port!, #"{"kind":"progress","stage":"\#(stage)","name":"m-1"}"#)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { reporter.cancel() }

        let text = try await readEvents(port: test.port!) { ids($0).count >= 24 }

        #expect(!text.contains(": keepalive"))
    }
}

/// `StreamOptions.buffer` reaches the stream: a stalled client of a 4-frame buffer is
/// dropped after a few events, well short of the 256-frame default.
@Test func streamEventsUsesTheConfiguredBuffer() async throws {
    let (provisioner, _) = try makeProvisioner()
    _ = try await provisioner.provision([request("m-1")])
    let directory = try temporaryDirectory()
    let handler = APIHandler(
        provisioner: provisioner,
        configuration: ServerConfiguration(port: 0, bind: "127.0.0.1", files: directory, dataDirectory: directory,
                                           advertiseAddress: "127.0.0.1:8234"),
        streamOptions: StreamOptions(keepalive: .seconds(60), limit: 1, buffer: 4), streams: StreamLimiter(limit: 1),
        serverName: "test", logger: testLogger)

    guard case .ok(let ok) = try await handler.streamEvents(.init(query: .init(), headers: .init())),
          case .textEventStream(let body) = ok.body
    else { Issue.record("no event stream"); return }
    for stage in Array(repeating: [Schemas.InstallStage.lateCommands, .identity], count: 5).joined() {
        _ = try await provisioner.report(report(.progress, stage, name: "m-1"))
    }

    let freed = TestFlag()
    try await poll(within: .seconds(2)) {
        if await handler.streams.acquire() { freed.set() }
        return freed.isSet
    }
    #expect(freed.isSet, "the stalled stream still holds its slot, so it was never dropped")
    withExtendedLifetime(body) {}
}

/// With no room past the `retry` frame, the first keepalive overflows and ends the stream.
@Test func keepaliveIntoAFullBufferEndsTheStream() async throws {
    let (live, _) = AsyncStream.makeStream(of: Schemas.MachineEvent.self)
    let cancelled = TestFlag()
    let released = TestFlag()
    let subscription = EventSubscription(backlog: .events([]), live: live, cancel: { cancelled.set() })

    let body = sseBody(subscription, keepalive: .milliseconds(50), buffer: 0) { released.set() }
    try await poll(within: .seconds(2)) { released.isSet }

    #expect(released.isSet, "a keepalive into a full buffer left the stream open")
    #expect(cancelled.isSet)
    withExtendedLifetime(body) {}
}
