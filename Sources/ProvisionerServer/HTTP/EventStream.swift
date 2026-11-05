import OpenAPIRuntime
import ProvisionerAPI

/// Caps the number of open event streams.
actor StreamLimiter {
    private let limit: Int
    private var open = 0

    init(limit: Int = 64) { self.limit = limit }

    func acquire() -> Bool {
        guard open < limit else { return false }
        open += 1
        return true
    }

    func release() { open -= 1 }
}

extension APIHandler {
    // Placeholder for the SSE endpoint, filled in by the event-stream task.
    func streamEvents(_ input: Operations.StreamEvents.Input) async throws -> Operations.StreamEvents.Output {
        .default(statusCode: 501, .init(body: .json(errorPayload(._internal, "not implemented"))))
    }
}
