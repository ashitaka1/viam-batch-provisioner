import Foundation

/// The queue, machine records and staged files on disk, loaded once and
/// written through. Not thread-safe: the `Provisioner` actor owns it.
final class MachineStore {
    private let dir: DataDirectory
    private(set) var queue: [QueueRecord]
    private var machines: [String: MachineRecord]

    init(_ dir: DataDirectory) throws(StoreError) {
        self.dir = dir
        let fm = FileManager.default
        do {
            try dir.prepare()
        } catch {
            throw .io("cannot prepare \(dir.root.path): \(error)")
        }
        if let data = fm.contents(atPath: dir.queue.path) {
            do {
                queue = try StoreCoding.decoder.decode([QueueRecord].self, from: data)
            } catch {
                throw .queueUnreadable("\(dir.queue.path) is not a valid queue: \(error)")
            }
        } else {
            queue = []
        }
        machines = [:]
        let files = (try? fm.contentsOfDirectory(atPath: dir.machines.path)) ?? []
        for file in files where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let key = String(file.dropLast(".json".count))
            guard let data = fm.contents(atPath: dir.machine(key).path) else { continue }
            do {
                machines[key] = try StoreCoding.decoder.decode(MachineRecord.self, from: data)
            } catch {
                throw .io("\(dir.machine(key).path) is not a valid machine record: \(error)")
            }
        }
    }

    func machine(_ key: String) -> MachineRecord? {
        machines[key]
    }

    func save(queue: [QueueRecord]) throws {
        try writeAtomically(StoreCoding.encoder.encode(queue), to: dir.queue)
        self.queue = queue
    }

    func save(machine: MachineRecord, key: String) throws {
        try writeAtomically(StoreCoding.encoder.encode(machine), to: dir.machine(key))
        machines[key] = machine
    }

    /// Writes whichever of the two files are given; a nil leaves that file as it is.
    func stage(credentials: Data?, environment: Data?, key: String) throws {
        let folder = dir.credentials(key)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let credentials {
            try writeAtomically(credentials, to: folder.appending(path: "viam.json"), mode: 0o600)
        }
        if let environment {
            try writeAtomically(environment, to: folder.appending(path: "environment.json"), mode: 0o600)
        }
    }

    func hasCredentials(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.credentials(key).appending(path: "viam.json").path)
    }

    func remove(key: String) throws {
        let fm = FileManager.default
        for url in [dir.machine(key), dir.credentials(key)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        machines[key] = nil
    }
}
