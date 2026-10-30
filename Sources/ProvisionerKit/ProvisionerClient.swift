public import Foundation
package import OpenAPIRuntime
import OpenAPIURLSession
package import ProvisionerAPI

public struct ProvisionResult: Sendable, Equatable {
    public var name: String
    public var added: Bool
    /// Why an item was skipped: `already-queued` or `duplicate-in-request`.
    public var reason: String?
}

public struct QueueSnapshot: Sendable, Equatable {
    public var entries: [QueueEntry]
    /// Newest event id when the snapshot was taken; stream events after it.
    public var lastEventID: Int
}

/// Calls the provisioner REST API at one server.
public struct ProvisionerClient: Sendable {
    private let client: Client

    public init(baseURL: URL) {
        self.init(baseURL: baseURL, transport: URLSessionTransport())
    }

    package init(baseURL: URL, transport: any ClientTransport) {
        client = Client(serverURL: baseURL, transport: transport)
    }

    public func provision(_ requests: [ProvisionRequest]) async throws(ProvisionerError) -> [ProvisionResult] {
        let body = try requests.map { r throws(ProvisionerError) in try r.wire() }
        return try await call {
            switch try await client.provision(body: .json(body)) {
            case .ok(let r):
                return try r.body.json.results.map {
                    ProvisionResult(name: $0.name, added: $0.result == .added, reason: $0.reason?.rawValue)
                }
            case .badRequest(let r): throw ProvisionerError(status: 400, try r.body.json)
            case .internalServerError(let r): throw ProvisionerError(status: 500, try r.body.json)
            case .serviceUnavailable(let r): throw ProvisionerError(status: 503, try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
    }

    public func queue() async throws(ProvisionerError) -> QueueSnapshot {
        try await call {
            switch try await client.listQueue() {
            case .ok(let r):
                let list = try r.body.json
                return QueueSnapshot(entries: list.entries.map(QueueEntry.init), lastEventID: list.lastEventId)
            case .serviceUnavailable(let r): throw ProvisionerError(status: 503, try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
    }

    public func entry(named name: String) async throws(ProvisionerError) -> QueueEntry {
        try await call {
            switch try await client.getQueueEntry(path: .init(name: name)) {
            case .ok(let r): return QueueEntry(try r.body.json)
            case .badRequest(let r): throw ProvisionerError(status: 400, try r.body.json)
            case .notFound(let r): throw ProvisionerError(status: 404, try r.body.json)
            case .serviceUnavailable(let r): throw ProvisionerError(status: 503, try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
    }

    public func remove(named name: String) async throws(ProvisionerError) {
        try await call {
            switch try await client.removeQueueEntry(path: .init(name: name)) {
            case .noContent: return
            case .badRequest(let r): throw ProvisionerError(status: 400, try r.body.json)
            case .notFound(let r): throw ProvisionerError(status: 404, try r.body.json)
            case .conflict(let r): throw ProvisionerError(status: 409, try r.body.json)
            case .serviceUnavailable(let r): throw ProvisionerError(status: 503, try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
    }

    public func status() async throws(ProvisionerError) -> ServerStatus {
        try await call {
            switch try await client.getStatus() {
            case .ok(let r): return ServerStatus(try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
    }

    /// Opens `/events` from `id`. Frames are passed through undecoded.
    public func eventFrames(after id: Int) async throws(ProvisionerError) -> AsyncThrowingStream<ServerSentEvent, any Error> {
        let body = try await call {
            switch try await client.streamEvents(headers: .init(lastEventID: id)) {
            case .ok(let r): return try r.body.textEventStream
            case .badRequest(let r): throw ProvisionerError(status: 400, try r.body.json)
            case .serviceUnavailable(let r): throw ProvisionerError(status: 503, try r.body.json)
            case .default(let status, let r): throw ProvisionerError(status: status, try r.body.json)
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in body.asDecodedServerSentEvents() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws(ProvisionerError) -> T {
        do {
            return try await body()
        } catch let error as ProvisionerError {
            throw error
        } catch let error as ClientError {
            if let response = error.response {
                throw .unexpectedResponse(status: response.status.code)
            }
            throw .transport(error.underlyingError)
        } catch {
            throw .transport(error)
        }
    }
}
