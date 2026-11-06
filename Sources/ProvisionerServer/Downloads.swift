import Foundation
import ProvisionerAPI

/// One image stream in flight and its last journaled progress.
struct DownloadMark: Sendable {
    let key: String
    /// The queue entry's `addedAt`, so a stream that outlives its entry records nothing on a re-queued one.
    let entry: Date
    let total: Int
    var bytes: Int
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

    /// Records the start of a stream to `name` and returns the id the stream
    /// reports under; nil when nothing is recorded for it.
    func downloadStarted(_ name: String, total: Int) -> UUID? {
        guard let (queued, store) = try? lookup(name) else { return nil }
        var record = store.machine(queued.key) ?? MachineRecord()
        guard derivedStatus(record) != .installed else { return nil }
        if record.attempt == 0 {
            record.attempt = 1
            record.attemptStartedAt = now()
        }
        let added = reach(.downloading, &record)
        record.downloadBytes = 0
        record.downloadTotal = total
        guard save(record, queued, store) else { return nil }
        let id = UUID()
        downloads[id] = DownloadMark(key: queued.key, entry: queued.addedAt, total: total, bytes: 0, at: now())
        if let added { announce(added, name: queued.name, mac: nil) }
        emitProgress(queued.name, bytes: 0, total: total)
        return id
    }

    func downloadProgressed(_ id: UUID, bytes: Int) {
        guard let mark = downloads[id] else { return }
        let time = now()
        guard Double(bytes - mark.bytes) >= progressFraction * Double(mark.total),
              time.timeIntervalSince(mark.at) >= progressInterval,
              let (queued, store, found) = downloadingMachine(mark) else { return }
        var record = found
        record.downloadBytes = bytes
        guard save(record, queued, store) else { return }
        downloads[id]?.bytes = bytes
        downloads[id]?.at = time
        emitProgress(queued.name, bytes: bytes, total: mark.total)
    }

    func downloadEnded(_ id: UUID, bytes: Int) {
        guard let mark = downloads.removeValue(forKey: id),
              let (queued, store, found) = downloadingMachine(mark) else { return }
        var record = found
        record.downloadBytes = bytes
        let added = bytes == mark.total ? reach(.installing, &record) : nil
        guard save(record, queued, store) else { return }
        if let added { announce(added, name: queued.name, mac: nil) }
        emitProgress(queued.name, bytes: bytes, total: mark.total)
    }

    /// The entry the stream started for and its record, unless that entry is
    /// gone or the machine is installed.
    private func downloadingMachine(_ mark: DownloadMark) -> (QueueRecord, MachineStore, MachineRecord)? {
        guard let (queued, store) = try? lookup(mark.key), queued.addedAt == mark.entry else { return nil }
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
