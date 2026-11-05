import Foundation
import Logging
import OpenAPIRuntime
import ProvisionerAPI

/// The contract's operations over the `Provisioner`.
struct APIHandler: APIProtocol {
    let provisioner: Provisioner
    let configuration: ServerConfiguration
    let streamOptions: StreamOptions
    let streams: StreamLimiter
    let serverName: String

    func provision(_ input: Operations.Provision.Input) async throws -> Operations.Provision.Output {
        guard case .json(let items) = input.body else { return .badRequest(badRequest(.invalidRequest, "expected JSON")) }
        do {
            return .ok(.init(body: .json(.init(results: try await provisioner.provision(items)))))
        } catch .queueUnreadable(let message) {
            return .serviceUnavailable(.init(body: .json(errorPayload(.queueUnreadable, message))))
        } catch .internal(let message) {
            return .internalServerError(.init(body: .json(errorPayload(._internal, message))))
        } catch {
            return failure(error)
        }
    }

    func reportInstall(_ input: Operations.ReportInstall.Input) async throws -> Operations.ReportInstall.Output {
        guard case .json(let report) = input.body else { return .badRequest(badRequest(.invalidRequest, "expected JSON")) }
        do {
            return .ok(.init(body: .json(.init(result: try await provisioner.report(report)))))
        } catch .notFound(let name) {
            return .notFound(notFound(name))
        } catch .queueUnreadable(let message) {
            return .serviceUnavailable(.init(body: .json(errorPayload(.queueUnreadable, message))))
        } catch {
            return failure(error)
        }
    }

    func listQueue(_ input: Operations.ListQueue.Input) async throws -> Operations.ListQueue.Output {
        do {
            let snapshot = try await provisioner.snapshot()
            return .ok(.init(body: .json(.init(lastEventId: snapshot.lastEventID, entries: snapshot.entries))))
        } catch .queueUnreadable(let message) {
            return .serviceUnavailable(.init(body: .json(errorPayload(.queueUnreadable, message))))
        } catch {
            return failure(error)
        }
    }

    func getQueueEntry(_ input: Operations.GetQueueEntry.Input) async throws -> Operations.GetQueueEntry.Output {
        do {
            return .ok(.init(body: .json(try await provisioner.entry(input.path.name))))
        } catch .notFound(let name) {
            return .notFound(notFound(name))
        } catch .queueUnreadable(let message) {
            return .serviceUnavailable(.init(body: .json(errorPayload(.queueUnreadable, message))))
        } catch {
            return failure(error)
        }
    }

    func removeQueueEntry(_ input: Operations.RemoveQueueEntry.Input) async throws -> Operations.RemoveQueueEntry.Output {
        do {
            try await provisioner.remove(input.path.name)
            return .noContent(.init())
        } catch .notFound(let name) {
            return .notFound(notFound(name))
        } catch .alreadyAssigned(let name) {
            return .conflict(.init(body: .json(errorPayload(.alreadyAssigned, "\(name) is installing"))))
        } catch .queueUnreadable(let message) {
            return .serviceUnavailable(.init(body: .json(errorPayload(.queueUnreadable, message))))
        } catch {
            return failure(error)
        }
    }

    func getStatus(_ input: Operations.GetStatus.Input) async throws -> Operations.GetStatus.Output {
        let counts = await provisioner.counts()
        let lastEventID = await provisioner.lastEventID
        return .ok(.init(body: .json(.init(
            apiVersion: .v1, serverName: serverName, time: Date(), address: configuration.advertiseAddress,
            queue: counts, services: .init(http: .up), lastEventId: lastEventID))))
    }

    // MARK: - Errors

    private func badRequest(_ code: ErrorCode, _ message: String,
                            details: [Components.Schemas.ErrorDetail]? = nil) -> Components.Responses.BadRequest {
        .init(body: .json(errorPayload(code, message, details: details)))
    }

    private func notFound(_ name: String) -> Components.Responses.NotFound {
        .init(body: .json(errorPayload(.notFound, "\(name) is not in the queue")))
    }

    /// The responses every operation shares: 400s and the `default` 500.
    private func failure<Output: FailureOutput>(_ error: ProvisionerFailure) -> Output {
        switch error {
        case .invalid(let message, let details):
            return .badRequest(badRequest(.invalidRequest, message, details: details))
        case .invalidName(let message):
            return .badRequest(badRequest(.invalidName, message))
        default:
            return .default(statusCode: 500, .init(body: .json(errorPayload(._internal, "\(error)"))))
        }
    }
}

/// The two response cases every operation's output has.
protocol FailureOutput {
    static func badRequest(_ response: Components.Responses.BadRequest) -> Self
    static func `default`(statusCode: Int, _ response: Components.Responses.UnexpectedError) -> Self
}

extension Operations.Provision.Output: FailureOutput {}
extension Operations.ReportInstall.Output: FailureOutput {}
extension Operations.GetQueueEntry.Output: FailureOutput {}
extension Operations.RemoveQueueEntry.Output: FailureOutput {}
extension Operations.StreamEvents.Output: FailureOutput {}

extension Operations.ListQueue.Output: FailureOutput {
    static func badRequest(_ response: Components.Responses.BadRequest) -> Self {
        .default(statusCode: 400, .init(body: .json((try? response.body.json) ?? errorPayload(.invalidRequest, "invalid request"))))
    }
}
