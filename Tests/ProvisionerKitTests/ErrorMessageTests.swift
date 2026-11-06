import Foundation
@testable import ProvisionerKit
import Testing

private struct Described: LocalizedError {
    let errorDescription: String?
}

private let refused = Described(errorDescription: "connection refused")

struct ErrorMessageTests {
    @Test(arguments: [
        (ProvisionerError.server(status: 409, code: "conflict", message: "m2 is installing", details: []), "m2 is installing"),
        (ProvisionerError.unexpectedResponse(status: 503), "The server answered with HTTP 503."),
        (ProvisionerError.transport(refused), "connection refused"),
        (ProvisionerError.invalidCredentials, "A machine's credentials aren't a valid viam.json."),
        (QueueFeed.StreamClosed(), "The server closed the event stream."),
        (refused, "connection refused"),
    ] as [(any Error, String)])
    func queueMessage(error: any Error, expected: String) {
        #expect(error.queueMessage == expected)
    }

    @Test(arguments: [
        (ProvisionerError.server(status: 422, code: "invalid", message: "Some machines can't be queued", details: [
            .init(index: 0, field: "name", message: "lab-1 is already queued"),
            .init(index: 2, field: "mac", message: "not a MAC address"),
        ]), "Some machines can't be queued: lab-1 is already queued; not a MAC address"),
        (ProvisionerError.server(status: 500, code: "internal", message: "The queue couldn't be written", details: []),
         "The queue couldn't be written"),
        (ProvisionerError.transport(refused), "connection refused"),
    ] as [(ProvisionerError, String)])
    func sendMessage(error: ProvisionerError, expected: String) {
        #expect(error.sendMessage == expected)
    }
}
