import Foundation
import ProvisionerAPI

enum PXEObservation: Sendable, Equatable {
    case offered(mac: String)
    case fileSent(filename: String, mac: String?)
}

protocol MachineBindings: Sendable {
    /// The queued machine name bound to `mac`, if any.
    func name(boundTo mac: String) async -> String?
}

struct NoBindings: MachineBindings {
    func name(boundTo mac: String) async -> String? { nil }
}

let bootFiles: Set<String> = ["hwe-vmlinuz", "hwe-initrd"]

extension Provisioner {
    func observe(_ observation: PXEObservation) async {
        switch observation {
        case .offered(let mac): await observeOffer(mac)
        case .fileSent(let filename, let mac): await observeFile(filename, mac)
        }
    }

    private func observeOffer(_ mac: String) async {
        guard let (queued, store, found) = await boundMachine(mac), found.completedAt == nil else { return }
        var record = found
        let current = record.steps.filter { $0.attempt == record.attempt }.map(\.step)
        if record.failedAt == nil, current == [Components.Schemas.ProvisioningStep.found.rawValue] { return }
        if record.attempt == 0 {
            record.attempt = 1
            record.attemptStartedAt = now()
        } else {
            beginAttempt(&record)
        }
        persist(&record, reaching: .found, queued, store, mac)
    }

    private func observeFile(_ filename: String, _ mac: String?) async {
        let file = filename.split(separator: "/").last.map(String.init) ?? filename
        guard bootFiles.contains(file), let mac else { return }
        guard let (queued, store, found) = await boundMachine(mac), found.completedAt == nil, found.attempt > 0,
              !found.bootFilesSent.contains(file) else { return }
        var record = found
        record.bootFilesSent.append(file)
        persist(&record, reaching: bootFiles.isSubset(of: record.bootFilesSent) ? .booting : nil, queued, store, mac)
    }

    /// Saves the record, then announces the step it reached. A save failure
    /// is logged and nothing is emitted.
    private func persist(_ record: inout MachineRecord, reaching step: Components.Schemas.ProvisioningStep?,
                         _ queued: QueueRecord, _ store: MachineStore, _ mac: String) {
        let added = step.flatMap { reach($0, &record) }
        do {
            try store.save(machine: record, key: queued.key)
        } catch {
            logger.error("recording an observation for \(queued.name) failed: \(error)")
            return
        }
        if let added { announce(added, name: queued.name, mac: mac) }
    }

    private func boundMachine(_ mac: String) async -> (QueueRecord, MachineStore, MachineRecord)? {
        guard let name = await bindings.name(boundTo: mac) else {
            logger.debug("observation from unbound MAC \(mac)")
            return nil
        }
        guard let store else {
            logger.debug("observation for \(name) dropped: queue unreadable")
            return nil
        }
        guard let queued = store.queue.first(where: { $0.key == name.lowercased() }) else {
            logger.debug("observation for \(name) dropped: not queued")
            return nil
        }
        return (queued, store, store.machine(queued.key) ?? MachineRecord())
    }
}
