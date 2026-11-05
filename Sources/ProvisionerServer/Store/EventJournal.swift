import Foundation
import Logging
import ProvisionerAPI

/// The append-only event log, one contract `MachineEvent` per line. Holds every
/// event in memory for replay. Not thread-safe: the `Provisioner` actor owns it.
final class EventJournal {
    private let url: URL
    private let logger: Logger
    private var events: [Components.Schemas.MachineEvent] = []
    private(set) var lastID = 0

    var firstID: Int? { events.first?.id }

    init(url: URL, logger: Logger) throws {
        self.url = url
        self.logger = logger
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let decoder = StoreCoding.decoder
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            do {
                let event = try decoder.decode(Components.Schemas.MachineEvent.self, from: Data(line))
                guard let id = event.id, id > lastID else { continue }
                events.append(event)
                lastID = id
            } catch {
                logger.error("skipping undecodable journal line: \(error)")
            }
        }
    }

    /// Appends the event `make` builds for the next id. A write failure is logged
    /// and returns nil; the id is not used.
    func append(_ make: (Int) -> Components.Schemas.MachineEvent) -> Components.Schemas.MachineEvent? {
        let event = make(lastID + 1)
        do {
            var line = try StoreCoding.encoder.encode(event)
            line.append(UInt8(ascii: "\n"))
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    throw StoreError.io("cannot create \(url.path)")
                }
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if handle.readData(ofLength: 1) != Data([UInt8(ascii: "\n")]) {
                    line.insert(UInt8(ascii: "\n"), at: 0)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            logger.error("journal write failed; event \(lastID + 1) is lost: \(error)")
            return nil
        }
        lastID += 1
        events.append(event)
        return event
    }

    func events(after id: Int) -> [Components.Schemas.MachineEvent] {
        Array(events.drop { ($0.id ?? 0) <= id })
    }
}

extension Components.Schemas.MachineEvent {
    /// The journal id; nil for `resync`, which has none.
    var id: Int? {
        switch self {
        case .machineAssigned(let e): e.id
        case .installStarted(let e): e.id
        case .installProgress(let e): e.id
        case .installFailed(let e): e.id
        case .installComplete(let e): e.id
        case .guardInstalled(let e): e.id
        case .resync: nil
        }
    }
}
