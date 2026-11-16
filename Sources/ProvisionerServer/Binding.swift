import Foundation
import ProvisionerAPI

/// `text` as a lowercase colon-separated MAC address, or nil unless it is six
/// pairs of hex digits all separated by `:` or all by `-`.
func normalizedMAC(_ text: String) -> String? {
    guard let separator = text.first(where: { $0 == ":" || $0 == "-" }) else { return nil }
    let parts = text.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
    return parts.joined(separator: ":").lowercased()
}

extension Provisioner {
    /// Binds `mac` to the queued `name`, replacing any MAC it had.
    func bind(_ name: String, mac text: String) throws(ProvisionerFailure) -> Components.Schemas.QueueEntry {
        let (queued, store) = try lookup(name)
        guard let mac = normalizedMAC(text) else {
            throw .invalid(message: "invalid binding", details: [.init(field: "mac", message: "must be a MAC address such as aa:bb:cc:dd:ee:ff")])
        }
        if let other = store.queue.first(where: { $0.mac == mac && $0.key != queued.key }) {
            throw .macBound(other.name)
        }
        if queued.mac == mac { return entry(queued, store) }
        let status = derivedStatus(store.machine(queued.key), bound: queued.mac != nil)
        if status == .installing { throw .notBindable("\(queued.name) is installing") }
        if status == .installed { throw .notBindable("\(queued.name) is installed; remove it and queue it again to reinstall") }
        if store.environment(queued.key) == nil { throw .notBindable("\(queued.name) was queued without an environment") }
        if bootImage == nil { throw .notBindable("the server has no boot image") }

        var bound = queued
        bound.mac = mac
        bound.boundAt = now()
        try saveQueue(replacing: bound, in: store)
        let time = now()
        emit { .machineAssigned(.init(id: $0, _type: .machineAssigned, timestamp: time, name: bound.name, mac: mac)) }
        return entry(bound, store)
    }

    /// Removes the queued `name`'s binding, if it has one.
    func unbind(_ name: String) throws(ProvisionerFailure) {
        let (queued, store) = try lookup(name)
        guard queued.mac != nil else { return }
        if derivedStatus(store.machine(queued.key), bound: true) == .installing {
            throw .alreadyAssigned(queued.name)
        }
        var unbound = queued
        unbound.mac = nil
        unbound.boundAt = nil
        try saveQueue(replacing: unbound, in: store)
    }

    private func saveQueue(replacing record: QueueRecord, in store: MachineStore) throws(ProvisionerFailure) {
        do {
            try store.save(queue: store.queue.map { $0.key == record.key ? record : $0 })
        } catch {
            logger.error("saving the binding of \(record.name) failed: \(error)")
            throw .internal("the binding of \(record.name) could not be saved")
        }
    }
}
