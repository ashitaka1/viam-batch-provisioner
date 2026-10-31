import Foundation

public enum ViamCLIError: Error, Equatable, Sendable {
    case notInstalled
    case notLoggedIn
    /// The CLI failed; carries its stderr, never its stdout.
    case failed(String)
    case unparsableOrganizations
    /// The key output didn't parse. Carries nothing: stdout may hold the key.
    case unparsableKey
}

/// The operator's `viam` CLI, which holds their login. Only stdout carries
/// results; the key never appears in arguments.
public struct ViamCLI: Sendable {
    public typealias Runner = @Sendable ([String]) async throws -> (status: Int32, stdout: String, stderr: String)

    private let run: Runner

    public init(run: @escaping Runner = ViamCLI.processRunner) {
        self.run = run
    }

    public func organizations() async throws -> [(id: String, name: String)] {
        let stdout = try await succeed(["organizations", "list"])
        // "\t<name> (id: <id>)" optionally followed by " (namespace: <ns>)".
        let pattern = /^\t(?<name>.+?) \(id: (?<id>[^)\s]+)\)(?: \(namespace: [^)]*\))?\s*$/
        let orgs = Self.lines(stdout).compactMap { line -> (id: String, name: String)? in
            guard let match = line.wholeMatch(of: pattern) else { return nil }
            return (String(match.id), String(match.name))
        }
        guard !orgs.isEmpty else { throw ViamCLIError.unparsableOrganizations }
        return orgs
    }

    public func createKey(orgID: String, name: String) async throws -> (id: String, key: String) {
        let stdout = try await succeed(["organizations", "api-key", "create", "--org-id", orgID, "--name", name])
        var id: String?
        var key: String?
        for line in Self.lines(stdout) {
            if line.hasPrefix("Key ID:") { id = line.dropFirst("Key ID:".count).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Key Value:") { key = line.dropFirst("Key Value:".count).trimmingCharacters(in: .whitespaces) }
        }
        guard let id, !id.isEmpty, let key, !key.isEmpty else { throw ViamCLIError.unparsableKey }
        return (id, key)
    }

    private func succeed(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        if result.status == 127 { throw ViamCLIError.notInstalled }
        let stderr = result.stderr.lowercased()
        if stderr.contains("not logged in") || stderr.contains("log in again") || stderr.contains("viam login") {
            throw ViamCLIError.notLoggedIn
        }
        guard result.status == 0 else { throw ViamCLIError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.stdout
    }

    /// Lines with ANSI color codes removed; the CLI colors its prefixes on a terminal.
    private static func lines(_ text: String) -> [String] {
        text.replacing(/\u{1B}\[[0-9;]*m/, with: "").components(separatedBy: .newlines)
    }

    /// Runs `viam` from PATH. `env` exits 127 when it isn't found.
    public static let processRunner: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["viam"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let (outData, errData) = await (out, err)
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
