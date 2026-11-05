import Foundation
import Logging
import ProvisionerAPI

enum ProvisionerFailure: Error, Equatable {
    case invalid(message: String, details: [Components.Schemas.ErrorDetail])
    case invalidName(String)
    case notFound(String)
    case alreadyAssigned(String)
    case queueUnreadable(String)
    case `internal`(String)
}

/// Owns the server's state: the queue, machine records, staged files and the
/// event journal. Every read derives status from the stored records.
actor Provisioner {
    let now: @Sendable () -> Date
    let logger: Logger
    let store: MachineStore?
    private let loadError: String?
    let journal: EventJournal
    private var fanout = EventFanout()

    init(dataDirectory: DataDirectory, now: @escaping @Sendable () -> Date = Date.init, logger: Logger) throws {
        self.now = now
        self.logger = logger
        do {
            store = try MachineStore(dataDirectory)
            loadError = nil
        } catch .queueUnreadable(let message) {
            logger.error("queue unreadable: \(message)")
            store = nil
            loadError = message
        }
        journal = try EventJournal(url: dataDirectory.journal, logger: logger)
    }

    var lastEventID: Int { journal.lastID }

    func provision(_ items: [Components.Schemas.ProvisionRequest]) throws(ProvisionerFailure) -> [Components.Schemas.ProvisionResult] {
        let store = try readableStore()
        try validate(items)
        let queued = Set(store.queue.map(\.key))
        var seen = Set<String>()
        var results: [Components.Schemas.ProvisionResult] = []
        var added: [QueueRecord] = []
        do {
            for item in items {
                let key = item.name.lowercased()
                if queued.contains(key) {
                    results.append(.init(name: item.name, result: .skipped, reason: .alreadyQueued))
                } else if !seen.insert(key).inserted {
                    results.append(.init(name: item.name, result: .skipped, reason: .duplicateInRequest))
                } else {
                    if item.credentials != nil || item.environment != nil {
                        try store.stage(credentials: try item.credentials.map { try StoreCoding.encoder.encode($0) },
                                        environment: try item.environment.map { try StoreCoding.encoder.encode($0) },
                                        key: key)
                    }
                    added.append(QueueRecord(name: item.name, addedAt: now()))
                    results.append(.init(name: item.name, result: .added))
                }
            }
            if !added.isEmpty {
                try store.save(queue: store.queue + added)
            }
        } catch {
            for record in added { try? store.remove(key: record.key) }
            throw .internal("credentials could not be staged; nothing was queued: \(error)")
        }
        return results
    }

    func snapshot() throws(ProvisionerFailure) -> (entries: [Components.Schemas.QueueEntry], lastEventID: Int) {
        let store = try readableStore()
        return (store.queue.map { entry($0, store) }, journal.lastID)
    }

    func entry(_ name: String) throws(ProvisionerFailure) -> Components.Schemas.QueueEntry {
        let (record, store) = try lookup(name)
        return entry(record, store)
    }

    func remove(_ name: String) throws(ProvisionerFailure) {
        let (record, store) = try lookup(name)
        if derivedStatus(store.machine(record.key)) == .installing {
            throw .alreadyAssigned(record.name)
        }
        do {
            try store.save(queue: store.queue.filter { $0.key != record.key })
            try store.remove(key: record.key)
        } catch {
            throw .internal("could not remove \(record.name): \(error)")
        }
    }

    func counts() -> Components.Schemas.QueueCounts? {
        guard let store else { return nil }
        var c = [Components.Schemas.EntryStatus: Int]()
        for record in store.queue { c[derivedStatus(store.machine(record.key)), default: 0] += 1 }
        func n(_ status: Components.Schemas.EntryStatus) -> Int { c[status] ?? 0 }
        return Components.Schemas.QueueCounts(queued: n(.queued), flashed: n(.flashed), assigned: n(.assigned),
                                              installing: n(.installing), installed: n(.installed), failed: n(.failed),
                                              total: store.queue.count)
    }

    /// The backlog after `id` and live delivery from the same actor turn, so no
    /// event is missed or repeated. `nil` means live only. An id ahead of the
    /// journal, or older than its first event, gets a resync.
    func subscribe(after id: Int?) -> EventSubscription {
        let backlog: Backlog
        if let id {
            let first = journal.firstID ?? journal.lastID + 1
            backlog = id > journal.lastID || id + 1 < first ? .resync(latestID: journal.lastID) : .events(journal.events(after: id))
        } else {
            backlog = .events([])
        }
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Components.Schemas.MachineEvent.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        fanout.add(key, continuation)
        return EventSubscription(backlog: backlog, live: stream, cancel: { continuation.finish() })
    }

    var subscriberCount: Int { fanout.count }

    func journalEvents(after id: Int) -> [Components.Schemas.MachineEvent] {
        journal.events(after: id)
    }

    func machineRecord(_ name: String) -> MachineRecord? {
        store?.machine(name.lowercased())
    }

    /// Journals the event and delivers it to open streams. A journal failure is
    /// logged by the journal and the event goes nowhere.
    func emit(_ make: (Int) -> Components.Schemas.MachineEvent) {
        if let event = journal.append(make) {
            fanout.publish(event)
        }
    }

    private func unsubscribe(_ key: UUID) {
        fanout.remove(key)
    }

    // MARK: - Helpers

    func readableStore() throws(ProvisionerFailure) -> MachineStore {
        guard let store else { throw .queueUnreadable(loadError ?? "queue unreadable") }
        return store
    }

    func lookup(_ name: String) throws(ProvisionerFailure) -> (QueueRecord, MachineStore) {
        let problems = nameProblems(name)
        guard problems.isEmpty else { throw .invalidName(problems.joined(separator: " ")) }
        let store = try readableStore()
        let key = name.lowercased()
        guard let record = store.queue.first(where: { $0.key == key }) else { throw .notFound(name) }
        return (record, store)
    }

    private func validate(_ items: [Components.Schemas.ProvisionRequest]) throws(ProvisionerFailure) {
        if items.isEmpty {
            throw .invalid(message: "at least one machine is required", details: [.init(message: "body is empty")])
        }
        if items.count > maxProvisionItems {
            throw .invalid(message: "at most \(maxProvisionItems) machines per request",
                           details: [.init(message: "\(items.count) items")])
        }
        var details: [Components.Schemas.ErrorDetail] = []
        for (index, item) in items.enumerated() {
            let problems = nameProblems(item.name)
            if !problems.isEmpty {
                details.append(.init(index: index, field: "name", message: problems.joined(separator: " ")))
            }
            if let credentials = item.credentials, !validCredentials(credentials) {
                details.append(.init(index: index, field: "credentials",
                                     message: "must be a viam.json object with cloud.id and cloud.secret"))
            }
        }
        if !details.isEmpty {
            throw .invalid(message: "invalid provision request", details: details)
        }
    }

    private func entry(_ record: QueueRecord, _ store: MachineStore) -> Components.Schemas.QueueEntry {
        let machine = store.machine(record.key)
        return .init(name: record.name, status: derivedStatus(machine),
                     completedAt: machine?.completedAt, failedAt: machine?.failedAt,
                     failureReason: machine?.failureReason,
                     stage: machine?.stage.flatMap(Components.Schemas.InstallStage.init(rawValue:)),
                     hasCredentials: store.hasCredentials(record.key))
    }
}
