import Foundation
@testable import ProvisionerKit
import Testing

private struct Described: LocalizedError {
    let errorDescription: String?
}

private let refused = Described(errorDescription: "connection refused")

struct MessageCase<Failure: Sendable>: Sendable, CustomTestStringConvertible {
    let name: String
    let error: Failure
    let expected: String
    var testDescription: String { name }
}

struct ErrorMessageTests {
    @Test(arguments: [
        MessageCase<any Error>(name: "server error uses its message",
                               error: ProvisionerError.server(status: 409, code: "conflict", message: "m2 is installing", details: []),
                               expected: "m2 is installing"),
        .init(name: "undocumented response names the status", error: ProvisionerError.unexpectedResponse(status: 503),
              expected: "The server answered with HTTP 503."),
        .init(name: "transport uses the underlying error", error: ProvisionerError.transport(refused), expected: "connection refused"),
        .init(name: "invalid credentials", error: ProvisionerError.invalidCredentials,
              expected: "A machine's credentials aren't a valid viam.json."),
        .init(name: "closed event stream", error: QueueFeed.StreamClosed(), expected: "The server closed the event stream."),
        .init(name: "any other error uses its description", error: refused, expected: "connection refused"),
    ])
    func queueMessage(_ test: MessageCase<any Error>) {
        #expect(test.error.queueMessage == test.expected)
    }

    @Test(arguments: [
        MessageCase(name: "details follow the message",
                    error: ProvisionerError.server(status: 422, code: "invalid", message: "Some machines can't be queued", details: [
                        .init(index: 0, field: "name", message: "lab-1 is already queued"),
                        .init(index: 2, field: "mac", message: "not a MAC address"),
                    ]),
                    expected: "Some machines can't be queued: lab-1 is already queued; not a MAC address"),
        .init(name: "no details: the message alone",
              error: ProvisionerError.server(status: 500, code: "internal", message: "The queue couldn't be written", details: []),
              expected: "The queue couldn't be written"),
    ])
    func sendMessage(_ test: MessageCase<ProvisionerError>) {
        #expect(test.error.sendMessage == test.expected)
    }
}
