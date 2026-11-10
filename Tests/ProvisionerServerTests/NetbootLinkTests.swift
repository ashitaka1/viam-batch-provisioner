#if canImport(ProvisionerNetbootXPC)
import Foundation
import os
import ProvisionerNetbootXPC
@testable import ProvisionerServer
import Testing

private let mac = "aa:bb:cc:00:00:01"
private let otherMAC = "aa:bb:cc:00:00:02"

@Test func netbootEventsMapToObservations() {
    #expect(PXEObservation(.offered(mac: mac, architecture: 7, uuid: nil)) == .offered(mac: mac))
    #expect(PXEObservation(.fileSent(filename: "hwe-vmlinuz", clientAddress: "10.0.0.5", mac: mac, bytes: 10))
        == .fileSent(filename: "hwe-vmlinuz", mac: mac))
    #expect(PXEObservation(.fileSent(filename: "grubx64.efi", clientAddress: "10.0.0.5", mac: nil, bytes: 10))
        == .fileSent(filename: "grubx64.efi", mac: nil))
}

/// Stands in for the netboot daemon: refuses the first `refusals` connections, then sends
/// each accepted connection the next of `events` when it asks `servingInterface`.
private final class FakeNetbootDaemon: NSObject, NSXPCListenerDelegate, ProvisionerNetbootProtocol, Sendable {
    private struct State {
        var refusalsLeft: Int
        var refused = 0
        var events: [NetbootEvent]
        var connections: [NSXPCConnection] = []
        var served: Set<ObjectIdentifier> = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(events: [NetbootEvent], refusals: Int = 0) {
        state = OSAllocatedUnfairLock(uncheckedState: State(refusalsLeft: refusals, events: events))
    }

    var refused: Int { state.withLockUnchecked { $0.refused } }

    func invalidateConnections() {
        for connection in state.withLockUnchecked({ $0.connections }) { connection.invalidate() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let refuse = state.withLockUnchecked { state in
            guard state.refusalsLeft > 0 else { return false }
            state.refusalsLeft -= 1
            state.refused += 1
            return true
        }
        if refuse { return false }
        connection.exportedInterface = ProvisionerNetbootXPC.netbootInterface()
        connection.exportedObject = self
        connection.remoteObjectInterface = ProvisionerNetbootXPC.eventsInterface()
        state.withLockUnchecked { $0.connections.append(connection) }
        connection.resume()
        return true
    }

    func servingInterface(reply: @escaping @Sendable (String?) -> Void) {
        reply(nil)
        guard let peer = NSXPCConnection.current() else { return }
        let event = state.withLockUnchecked { state -> NetbootEvent? in
            guard !state.events.isEmpty, state.served.insert(ObjectIdentifier(peer)).inserted else { return nil }
            return state.events.removeFirst()
        }
        guard let event, let data = try? event.encoded(),
              let events = peer.remoteObjectProxy as? any ProvisionerNetbootEventsProtocol else { return }
        events.netbootEvent(data)
    }

    func serve(interface: String, bootFilename: String, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
    func stopServing(reply: @escaping @Sendable () -> Void) { reply() }
    func writeFile(_ path: String, contents: Data, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
    func removeFile(_ path: String, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
}

/// A provisioner with `m-1` and `m-2` queued, linked to `daemon` until `body` returns.
private func linked(to daemon: FakeNetbootDaemon, retry: Duration = .milliseconds(20),
                    _ body: (Provisioner) async throws -> Void) async throws {
    let (provisioner, _) = try makeProvisioner(bindings: FixedBindings())
    _ = try await provisioner.provision([request("m-1"), request("m-2")])
    let listener = NSXPCListener.anonymous()
    listener.delegate = daemon
    listener.resume()
    defer { listener.invalidate() }
    let endpoint = listener.endpoint
    let client = NetbootClient { NSXPCConnection(listenerEndpoint: endpoint) }
    let link = Task { await linkNetbootDaemon(client, to: provisioner, logger: testLogger, retry: retry) }
    try await body(provisioner)
    client.invalidate()
    await link.value
}

private func steps(_ provisioner: Provisioner, _ name: String) async -> [String] {
    ((try? await provisioner.entry(name).steps) ?? nil)?.map(\.step.rawValue) ?? []
}

private func linkedSteps(refusals: Int) async throws -> [String] {
    let daemon = FakeNetbootDaemon(events: [.offered(mac: mac, architecture: 7, uuid: nil)], refusals: refusals)
    var found: [String] = []
    try await linked(to: daemon) { provisioner in
        try await poll(within: .seconds(5)) { await !steps(provisioner, "m-1").isEmpty }
        found = await steps(provisioner, "m-1")
    }
    return found
}

@Test func linkForwardsEventsAfterRegistering() async throws {
    #expect(try await linkedSteps(refusals: 0) == ["found"])
}

@Test func linkRetriesUntilTheNetbootDaemonAccepts() async throws {
    #expect(try await linkedSteps(refusals: 2) == ["found"])
}

/// The endpoint the client connects to, which the test moves when it replaces the netboot daemon.
private final class CurrentEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: NSXPCListenerEndpoint

    init(_ endpoint: NSXPCListenerEndpoint) { self.endpoint = endpoint }

    var value: NSXPCListenerEndpoint {
        get { lock.withLock { endpoint } }
        set { lock.withLock { endpoint = newValue } }
    }
}

@Test func linkRegistersWithAReplacedNetbootDaemon() async throws {
    let (provisioner, _) = try makeProvisioner(bindings: FixedBindings())
    _ = try await provisioner.provision([request("m-1"), request("m-2")])
    let first = FakeNetbootDaemon(events: [.offered(mac: mac, architecture: 7, uuid: nil)])
    let firstListener = NSXPCListener.anonymous()
    firstListener.delegate = first
    firstListener.resume()
    let endpoint = CurrentEndpoint(firstListener.endpoint)
    let client = NetbootClient { NSXPCConnection(listenerEndpoint: endpoint.value) }
    let link = Task { await linkNetbootDaemon(client, to: provisioner, logger: testLogger, retry: .milliseconds(20)) }
    try await poll(within: .seconds(5)) { await steps(provisioner, "m-1") == ["found"] }

    let second = FakeNetbootDaemon(events: [.offered(mac: otherMAC, architecture: 7, uuid: nil)])
    let secondListener = NSXPCListener.anonymous()
    secondListener.delegate = second
    secondListener.resume()
    defer { secondListener.invalidate() }
    endpoint.value = secondListener.endpoint
    first.invalidateConnections()
    firstListener.invalidate()
    try await poll(within: .seconds(5)) { await !steps(provisioner, "m-2").isEmpty }

    client.invalidate()
    await link.value
    #expect(await steps(provisioner, "m-1") == ["found"])
    #expect(await steps(provisioner, "m-2") == ["found"])
}

/// Runs `linkNetbootDaemon` against a netboot daemon that refuses every connection, ends it with
/// `stop` once the netboot daemon has refused one, and returns how long it took to return.
private func timeToEnd(after stop: (NetbootClient, Task<Void, Never>) -> Void) async throws -> Duration {
    let (provisioner, _) = try makeProvisioner(bindings: FixedBindings())
    let daemon = FakeNetbootDaemon(events: [], refusals: .max)
    let listener = NSXPCListener.anonymous()
    listener.delegate = daemon
    listener.resume()
    defer { listener.invalidate() }
    let endpoint = listener.endpoint
    let client = NetbootClient { NSXPCConnection(listenerEndpoint: endpoint) }
    let link = Task { await linkNetbootDaemon(client, to: provisioner, logger: testLogger, retry: .seconds(30)) }
    try await poll(within: .seconds(5)) { daemon.refused > 0 }
    try #require(daemon.refused > 0)
    let started = ContinuousClock.now
    stop(client, link)
    await link.value
    return ContinuousClock.now - started
}

@Test func cancellingTheLinkEndsItWhileNoNetbootDaemonAnswers() async throws {
    let elapsed = try await timeToEnd { _, link in link.cancel() }
    #expect(elapsed < .seconds(5), "the link took \(elapsed) to end after cancellation")
}

@Test func invalidatingTheClientEndsTheLinkWhileNoNetbootDaemonAnswers() async throws {
    let elapsed = try await timeToEnd { client, _ in client.invalidate() }
    #expect(elapsed < .seconds(5), "the link took \(elapsed) to end after invalidation")
}
#endif
