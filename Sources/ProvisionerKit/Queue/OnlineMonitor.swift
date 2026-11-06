public import Foundation
public import Observation
import os

/// Marks installed full-mode machines online once Viam reports them, for the machines this Mac provisioned on one server.
@MainActor @Observable
public final class OnlineMonitor {
    private static let log = Logger(subsystem: "ProvisionerKit", category: "OnlineMonitor")

    /// When each machine was first seen online.
    public private(set) var onlineAt: [String: Date] = [:]

    private let serverURL: URL
    private let history: BatchHistory
    private let fleet: @Sendable (String) -> any ViamFleet
    private let interval: Duration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(serverURL: URL, history: BatchHistory, fleet: @escaping @Sendable (String) -> any ViamFleet,
                interval: Duration = .seconds(30), now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.serverURL = serverURL
        self.history = history
        self.fleet = fleet
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    /// Asks Viam about the installed full-mode machines not yet seen online, one listing per location.
    public func check(_ entries: [QueueEntry]) async {
        let waiting = Set(entries.filter { $0.status == .installed && $0.provisionMode == .full && onlineAt[$0.name] == nil }.map(\.name))
        guard !waiting.isEmpty else { return }

        struct Place: Hashable { var orgID: String, locationID: String }
        var byPlace: [Place: Set<String>] = [:]
        for record in history.records where record.serverURL == serverURL {
            guard let orgID = record.orgID, let locationID = record.locationID else { continue }
            let names = waiting.intersection(record.machines)
            if !names.isEmpty { byPlace[Place(orgID: orgID, locationID: locationID), default: []].formUnion(names) }
        }

        for (place, names) in byPlace {
            do {
                let machines = try await fleet(place.orgID).machines(location: place.locationID)
                let seen = now()
                for machine in machines where machine.online && names.contains(machine.name) && onlineAt[machine.name] == nil {
                    onlineAt[machine.name] = seen
                }
            } catch {
                Self.log.error("Couldn't list machines in location \(place.locationID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Checks the queue's machines every interval until cancelled.
    public func run(_ queue: QueueModel) async {
        while !Task.isCancelled {
            await check(queue.entries)
            do { try await sleep(interval) } catch { return }
        }
    }
}
