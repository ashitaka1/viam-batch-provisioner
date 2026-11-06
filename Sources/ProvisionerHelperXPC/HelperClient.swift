import Foundation
import os

/// The helper's peer side: calls the helper and streams its events.
///
/// Connects on first use. When launchd restarts the helper, the client reconnects, so `events`
/// continues, and asks it to serve again with the arguments of the last `serve` that succeeded
/// and wasn't followed by a failed `serve` or a `stopServing`. After an invalidation, the next
/// call connects afresh.
public final class HelperClient: Sendable {
    /// Every event from the helper, across reconnections. Finishes on `invalidate()`.
    public let events: AsyncStream<HelperEvent>

    private struct State {
        var connection: NSXPCConnection?
        var serving: (interface: String, bootFilename: String)?
        var invalidated = false
    }

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let continuation: AsyncStream<HelperEvent>.Continuation
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public static let machService: @Sendable () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: ProvisionerHelperXPC.machServiceName, options: .privileged)
    }

    public init(makeConnection: @escaping @Sendable () -> NSXPCConnection = HelperClient.machService) {
        self.makeConnection = makeConnection
        (events, continuation) = AsyncStream.makeStream(of: HelperEvent.self, bufferingPolicy: .bufferingNewest(1024))
    }

    public func serve(interface: String, bootFilename: String) async throws {
        do {
            try await call { helper, reply in helper.serve(interface: interface, bootFilename: bootFilename, reply: reply) }
            state.withLockUnchecked { $0.serving = (interface, bootFilename) }
        } catch HelperError.serveFailed(let detail) {
            // The helper stopped the old server before the new one failed.
            state.withLockUnchecked { $0.serving = nil }
            throw HelperError.serveFailed(detail)
        }
    }

    public func stopServing() async throws {
        state.withLockUnchecked { $0.serving = nil }
        try await call { helper, reply in helper.stopServing { reply(nil) } }
    }

    /// The interface the helper serves, nil when it serves none. Registers this client for events.
    public func servingInterface() async throws -> String? {
        try await request { helper, reply in helper.servingInterface { reply(.success($0)) } }
    }

    public func writeFile(_ path: String, contents: Data) async throws {
        try await call { helper, reply in helper.writeFile(path, contents: contents, reply: reply) }
    }

    public func removeFile(_ path: String) async throws {
        try await call { helper, reply in helper.removeFile(path, reply: reply) }
    }

    /// Closes the connection and finishes `events`. Later calls throw `HelperError.invalidated`.
    public func invalidate() {
        let connection = state.withLockUnchecked { state in
            state.invalidated = true
            defer { state.connection = nil }
            return state.connection
        }
        connection?.invalidate()
        continuation.finish()
    }

    private func call(_ body: (any ProvisionerHelperProtocol, @escaping @Sendable (NSError?) -> Void) -> Void) async throws {
        try await request { helper, reply in
            body(helper) { error in reply(error.map { .failure(HelperError($0)) } ?? .success(())) }
        }
    }

    private func request<T: Sendable>(
        _ body: (any ProvisionerHelperProtocol, @escaping @Sendable (Result<T, HelperError>) -> Void) -> Void
    ) async throws -> T {
        guard let connection = connection() else { throw HelperError.invalidated }
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<T, any Error>) in
            let once = ResumeOnce(waiter)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperError.connection((error as NSError).localizedDescription)))
            }
            guard let helper = proxy as? any ProvisionerHelperProtocol else {
                once.resume(with: .failure(HelperError.connection("proxy does not conform")))
                return
            }
            body(helper) { once.resume(with: $0.mapError { $0 }) }
        }
    }

    /// Publishes a connection only once it is configured and resumed, so a concurrent caller never
    /// gets one without its interfaces. A caller that loses the race to publish invalidates its own.
    private func connection() -> NSXPCConnection? {
        let (invalidated, existing) = state.withLockUnchecked { ($0.invalidated, $0.connection) }
        if invalidated { return nil }
        if let existing { return existing }

        let fresh = configuredConnection()
        let published = state.withLockUnchecked { state -> NSXPCConnection? in
            guard !state.invalidated else { return nil }
            if let connection = state.connection { return connection }
            state.connection = fresh
            return fresh
        }
        if published !== fresh { fresh.invalidate() }
        return published
    }

    private func configuredConnection() -> NSXPCConnection {
        let connection = makeConnection()
        connection.remoteObjectInterface = ProvisionerHelperXPC.helperInterface()
        connection.exportedInterface = ProvisionerHelperXPC.eventsInterface()
        connection.exportedObject = EventReceiver(continuation: continuation)
        connection.interruptionHandler = { [weak self] in self?.resumeServing() }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.state.withLockUnchecked { state in
                if state.connection === connection { state.connection = nil }
            }
        }
        connection.resume()
        return connection
    }

    /// The helper restarted and serves nothing. Any message reconnects this client for events;
    /// then ask again for what it served.
    private func resumeServing() {
        let serving = state.withLockUnchecked { $0.serving }
        Task {
            do {
                if let serving {
                    try await call { helper, reply in helper.serve(interface: serving.interface, bootFilename: serving.bootFilename, reply: reply) }
                } else {
                    _ = try await servingInterface()
                }
            } catch {
                Logger(subsystem: ProvisionerHelperXPC.machServiceName, category: "client")
                    .error("serving again after the helper restarted failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

private final class EventReceiver: NSObject, ProvisionerHelperEventsProtocol, Sendable {
    private let continuation: AsyncStream<HelperEvent>.Continuation

    init(continuation: AsyncStream<HelperEvent>.Continuation) {
        self.continuation = continuation
    }

    func helperEvent(_ event: Data) {
        guard let event = try? HelperEvent(encoded: event) else {
            Logger(subsystem: ProvisionerHelperXPC.machServiceName, category: "client").error("undecodable helper event")
            return
        }
        continuation.yield(event)
    }
}

/// XPC calls either the reply or the error handler; this resumes the continuation for the first.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let waiter: OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>

    init(_ waiter: CheckedContinuation<T, any Error>) {
        self.waiter = OSAllocatedUnfairLock(initialState: waiter)
    }

    func resume(with result: Result<T, any Error>) {
        waiter.withLock { $0.take() }?.resume(with: result)
    }
}
