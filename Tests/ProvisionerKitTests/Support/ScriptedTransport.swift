import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers each request with the next scripted response and records what was sent.
final class ScriptedTransport: ClientTransport, @unchecked Sendable {
    struct Sent {
        var request: HTTPRequest
        var body: Data?
    }

    private let lock = NSLock()
    private var responses: [(HTTPResponse, HTTPBody?)]
    private(set) var sent: [Sent] = []

    init(_ responses: [(status: Int, contentType: String, body: String)]) {
        self.responses = responses.map { response in
            var head = HTTPResponse(status: .init(code: response.status))
            head.headerFields[.contentType] = response.contentType
            return (head, HTTPBody(response.body))
        }
    }

    convenience init(json status: Int, _ body: String) {
        self.init([(status, "application/json", body)])
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data = if let body { try await Data(collecting: body, upTo: 1 << 20) } else { Data?.none }
        return lock.withLock {
            sent.append(Sent(request: request, body: data))
            return responses.removeFirst()
        }
    }
}
