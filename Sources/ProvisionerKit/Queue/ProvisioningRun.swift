import Foundation
public import Observation

/// The calls a provisioning run makes to the server.
public protocol QueueWriter: Sendable {
    func queue() async throws(ProvisionerError) -> QueueSnapshot
    func provision(_ requests: [ProvisionRequest]) async throws(ProvisionerError) -> [ProvisionResult]
}

extension ProvisionerClient: QueueWriter {}

public struct BatchOutcome: Sendable, Equatable {
    /// Names the server added to its queue.
    public var queued: [String] = []
    /// Items the server didn't add, with its reason.
    public var skipped: [ProvisionResult] = []
    public var viamFailures: [MachineFailure] = []
    public var stop: BatchStop?
    /// Names never tried in Viam because the batch stopped.
    public var untried: [String] = []
    /// Created in Viam but not on the queue: the send failed, or the server skipped them.
    public var unqueued: [ProvisionedMachine] = []
    /// Names whose send failed; a retry sends them again.
    public var unsent: [String] = []
    /// Why the last send failed.
    public var sendError: String?
    /// Unqueued machines deleted from Viam.
    public var deletedFromViam: [String] = []
    /// Which unqueued machines Viam didn't delete, and why.
    public var deleteError: String?

    /// One sentence per machine that wasn't queued.
    public var problems: [String] {
        var problems = viamFailures.map {
            "\($0.name) wasn't created: \($0.message)." + ($0.leftInViam ? " It may remain in Viam." : "")
        }
        let unqueuedNames = Set(unqueued.map(\.name))
        problems += unsent.map {
            "\($0) wasn't queued" + (sendError.map { ": \($0)." } ?? ".")
                + (unqueuedNames.contains($0) ? " It was created in Viam." : "")
        }
        problems += skipped.map {
            "\($0.name) was skipped: \($0.reason ?? "no reason given")."
                + (unqueuedNames.contains($0.name) ? " It was created in Viam." : "")
        }
        problems += deletedFromViam.map { "\($0) was deleted from Viam after it wasn't queued." }
        problems += untried.map { "\($0) wasn't tried." }
        return problems
    }
}

/// One batch, provisioned from an environment: reads the queue for names in
/// use, creates the machines in Viam in full mode, then queues them with the
/// environment's settings. Agent and OS-only batches queue names alone.
@MainActor @Observable
public final class ProvisioningRun {
    public enum Phase: Equatable, Sendable {
        case ready
        case readingQueue
        case creatingInViam
        case sending
        case finished
        /// Stopped before any machine was created or queued.
        case failed(String)
    }

    public let environment: Environment
    public private(set) var phase: Phase = .ready
    public private(set) var outcome = BatchOutcome()

    private let config: EnvironmentConfig
    private let server: any QueueWriter
    private let fleet: (any ViamFleet)?
    /// Requests whose send failed.
    private var pending: [ProvisionRequest] = []

    /// `fleet` is the environment's org, needed in full mode.
    public init(environment: Environment, config: EnvironmentConfig, server: any QueueWriter, fleet: (any ViamFleet)?) {
        self.environment = environment
        self.config = config
        self.server = server
        self.fleet = fleet
    }

    public func start(count: Int) async {
        guard phase == .ready else { return }
        phase = .readingQueue
        let queued: Set<String>
        do {
            queued = Set(try await server.queue().entries.map(\.name))
        } catch {
            phase = .failed(error.queueMessage)
            return
        }

        if environment.provisionMode == .full {
            guard let fleet, let location = environment.locationID, !location.isEmpty else {
                phase = .failed("Choose a Viam organization and location for \(environment.name).")
                return
            }
            phase = .creatingInViam
            let result: BatchResult
            do {
                result = try await MachineBatch(fleet: fleet, location: location)
                    .create(prefix: environment.namePrefix, count: count, queued: queued)
            } catch {
                phase = .failed(error.message)
                return
            }
            outcome.viamFailures = result.failures
            outcome.stop = result.stop
            outcome.untried = result.untried
            outcome.unqueued = result.created
            await send(result.created.map {
                ProvisionRequest(name: $0.name, credentialsJSON: $0.credentialsJSON, environment: config)
            })
        } else {
            let names: [String]
            do {
                names = try MachineNaming.names(prefix: environment.namePrefix, count: count, existing: [], queued: queued)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            await send(names.map { ProvisionRequest(name: $0, environment: config) })
        }
        phase = .finished
    }

    public var canRetry: Bool { phase == .finished && !pending.isEmpty }

    /// Sends again the requests whose send failed.
    public func retrySending() async {
        guard canRetry else { return }
        await send(pending)
        phase = .finished
    }

    /// Deletes from Viam the machines created but not queued.
    public func deleteUnqueued() async {
        guard phase == .finished, let fleet else { return }
        var kept: [ProvisionedMachine] = []
        var problems: [String] = []
        for machine in outcome.unqueued {
            do {
                try await fleet.deleteMachine(id: machine.machineID)
                outcome.deletedFromViam.append(machine.name)
                outcome.unsent.removeAll { $0 == machine.name }
                outcome.skipped.removeAll { $0.name == machine.name }
                pending.removeAll { $0.name == machine.name }
            } catch {
                kept.append(machine)
                problems.append("\(machine.name): \(error.message)")
            }
        }
        outcome.unqueued = kept
        outcome.deleteError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func send(_ requests: [ProvisionRequest]) async {
        guard !requests.isEmpty else { return }
        phase = .sending
        do {
            let results = try await server.provision(requests)
            let added = Set(results.filter(\.added).map(\.name))
            outcome.queued += requests.map(\.name).filter(added.contains)
            outcome.skipped += results.filter { !$0.added }
            outcome.unqueued.removeAll { added.contains($0.name) }
            outcome.unsent = []
            outcome.sendError = nil
            pending = []
        } catch {
            outcome.unsent = requests.map(\.name)
            outcome.sendError = error.sendMessage
            pending = requests
        }
    }
}

extension ProvisionerError {
    /// The server's message with each item's problem, or the transport's.
    public var sendMessage: String {
        if case .server(_, _, let message, let details) = self, !details.isEmpty {
            return "\(message): " + details.map(\.message).joined(separator: "; ")
        }
        return queueMessage
    }
}

extension BatchError {
    var message: String {
        switch self {
        case .naming(let error): error.localizedDescription
        case .fleet(let error): error.message
        }
    }
}
