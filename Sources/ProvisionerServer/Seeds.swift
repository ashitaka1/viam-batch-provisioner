import Foundation
import ProvisionerAPI

/// 128 random bits as 32 lowercase hex digits.
func mintToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<2).map { _ in
        let hex = String(generator.next() as UInt64, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }.joined()
}

enum SeedFailure: Error, Equatable {
    case notFound
    case badHost
    case unsaved
}

/// Equal strings, compared in time that depends only on their lengths.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

extension Provisioner {
    /// Where the machine fetches its seed files, or nil when it isn't queued or
    /// was queued without an environment.
    func seedPath(for name: String) -> String? {
        guard let (queued, store) = try? lookup(name), let token = store.token(queued.key) else { return nil }
        return "/machines/by-name/\(queued.name)/\(token)/"
    }

    /// One of the machine's seed files. `user-data`, `viam.json` and `tailscale.key`
    /// are served once per attempt, and the time is saved before they are
    /// returned. `host` is the server address the machine used, rendered into
    /// `user-data`.
    func seedFile(_ file: String, name: String, token: String, host: String?) throws(SeedFailure) -> Data {
        guard let (queued, store) = try? lookup(name), let staged = store.token(queued.key),
              constantTimeEqual(staged, token) else { throw .notFound }
        var record = store.machine(queued.key) ?? MachineRecord()
        guard record.completedAt == nil else { throw .notFound }
        let environment = store.environment(queued.key)
            .flatMap { try? StoreCoding.decoder.decode(Components.Schemas.Environment.self, from: $0) }
        let content: Data?
        switch file {
        case "meta-data", "vendor-data":
            return Data()
        case "user-data":
            guard let host, validServerHost(host) else { throw .badHost }
            let machineURL = "http://\(host)/machines/by-name/\(queued.name)/\(staged)"
            content = environment.map { Data(renderUserData($0, server: host, machineURL: machineURL).utf8) }
        case "viam.json":
            content = store.credentials(queued.key)
        case "tailscale.key":
            content = environment?.tailscaleAuthKey.map { Data($0.utf8) }
        default:
            throw .notFound
        }
        guard record.secretsServed[file] == nil, let content else { throw .notFound }
        record.secretsServed[file] = now()
        var added: StepRecord?
        if file == "user-data" {
            if record.attempt == 0 {
                record.attempt = 1
                record.attemptStartedAt = now()
            }
            added = reach(.installing, &record)
        }
        do {
            try store.save(machine: record, key: queued.key)
        } catch {
            logger.error("recording that \(queued.name) fetched \(file) failed: \(error)")
            throw .unsaved
        }
        if let added { announce(added, name: queued.name, mac: nil) }
        return content
    }
}
