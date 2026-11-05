import Foundation

/// The server's data directory. Keys are lowercased machine names.
struct DataDirectory: Sendable {
    let root: URL

    init(_ root: URL) {
        self.root = root
    }

    var queue: URL { root.appending(path: "queue.json") }
    var journal: URL { root.appending(path: "events.jsonl") }
    var machines: URL { root.appending(path: "machines") }
    var credentialsRoot: URL { root.appending(path: "credentials") }

    func machine(_ key: String) -> URL { machines.appending(path: "\(key).json") }
    func credentials(_ key: String) -> URL { credentialsRoot.appending(path: key) }

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: machines, withIntermediateDirectories: true)
        try fm.createDirectory(at: credentialsRoot, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credentialsRoot.path)
    }
}

/// Writes `data` to a temporary file beside `url`, syncs it, renames it over
/// `url`, then syncs the directory so the rename survives a power loss.
func writeAtomically(_ data: Data, to url: URL, mode: Int = 0o644) throws {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    let temp = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: mode]) else {
        throw StoreError.io("cannot write \(temp.path)")
    }
    do {
        let handle = try FileHandle(forUpdating: temp)
        defer { try? handle.close() }
        try handle.synchronize()
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    } catch {
        try? fm.removeItem(at: temp)
        throw error
    }
    try syncDirectory(directory)
}

private func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw StoreError.io("cannot open \(directory.path)") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw StoreError.io("cannot sync \(directory.path)") }
}
