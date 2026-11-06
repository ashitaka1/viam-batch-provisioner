import Foundation
import ProvisionerAPI

struct DownloadMark: Sendable {
    var bytes: Int
    var total: Int
    var at: Date
}

/// Progress is journaled when it has advanced by this fraction of the image
/// and this long has passed since the last journaled progress.
private let progressFraction = 0.05
private let progressInterval: TimeInterval = 5

extension Provisioner {
    /// The boot image when `file` names it and `name` is queued.
    func bootImage(for name: String, file: String) -> BootImage? {
        guard let bootImage, file == bootImage.fileName, (try? lookup(name)) != nil else { return nil }
        return bootImage
    }

    func downloadStarted(_ name: String, total: Int) {
        guard let (queued, store, found) = downloadingMachine(name) else { return }
        var record = found
        if record.attempt == 0 {
            record.attempt = 1
            record.attemptStartedAt = now()
        }
        let added = reach(.downloading, &record)
        record.downloadBytes = 0
        record.downloadTotal = total
        guard save(record, queued, store) else { return }
        downloads[queued.key] = DownloadMark(bytes: 0, total: total, at: now())
        if let added { announce(added, name: queued.name, mac: nil) }
        emitProgress(queued.name, bytes: 0, total: total)
    }

    func downloadProgressed(_ name: String, bytes: Int) {
        let key = name.lowercased()
        guard let mark = downloads[key] else { return }
        let time = now()
        guard Double(bytes - mark.bytes) >= progressFraction * Double(mark.total),
              time.timeIntervalSince(mark.at) >= progressInterval,
              let (queued, store, found) = downloadingMachine(name) else { return }
        var record = found
        record.downloadBytes = bytes
        guard save(record, queued, store) else { return }
        downloads[key] = DownloadMark(bytes: bytes, total: mark.total, at: time)
        emitProgress(queued.name, bytes: bytes, total: mark.total)
    }

    func downloadEnded(_ name: String, bytes: Int) {
        guard let mark = downloads.removeValue(forKey: name.lowercased()),
              let (queued, store, found) = downloadingMachine(name) else { return }
        var record = found
        record.downloadBytes = bytes
        let added = bytes == mark.total ? reach(.installing, &record) : nil
        guard save(record, queued, store) else { return }
        if let added { announce(added, name: queued.name, mac: nil) }
        emitProgress(queued.name, bytes: bytes, total: mark.total)
    }

    /// The queued machine `name` and its record, unless it is installed.
    private func downloadingMachine(_ name: String) -> (QueueRecord, MachineStore, MachineRecord)? {
        guard let (queued, store) = try? lookup(name) else { return nil }
        let record = store.machine(queued.key) ?? MachineRecord()
        return derivedStatus(record) == .installed ? nil : (queued, store, record)
    }

    /// Saves the record; a failure is logged and the caller emits nothing.
    private func save(_ record: MachineRecord, _ queued: QueueRecord, _ store: MachineStore) -> Bool {
        do {
            try store.save(machine: record, key: queued.key)
            return true
        } catch {
            logger.error("recording the download for \(queued.name) failed: \(error)")
            return false
        }
    }

    private func emitProgress(_ name: String, bytes: Int, total: Int) {
        let time = now()
        emit {
            .downloadProgress(.init(id: $0, _type: .downloadProgress, timestamp: time, name: name, mac: nil,
                                    bytes: bytes, total: total))
        }
    }
}
