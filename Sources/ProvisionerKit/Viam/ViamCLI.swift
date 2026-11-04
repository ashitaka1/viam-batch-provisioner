public import Foundation

public enum ViamCLIError: Error, Equatable, Sendable {
    case notInstalled
    case notLoggedIn
    /// The CLI failed; carries its stderr, never its stdout.
    case failed(String)
    case unparsableOrganizations
    /// The key output didn't parse. Carries nothing: stdout may hold the key.
    case unparsableKey
    /// The token couldn't be read. Carries nothing: both streams hold the token.
    case tokenUnavailable
}

/// The operator's `viam` CLI, which holds their login. Only stdout carries
/// results; the key never appears in arguments.
public struct ViamCLI: Sendable {
    /// Runs the CLI with `arguments`, handing each line of stdout to `onLine` as it
    /// arrives, and returns once the CLI has exited.
    public typealias Runner = @Sendable (_ arguments: [String], _ onLine: @escaping @Sendable (String) -> Void) async throws
        -> (status: Int32, stdout: String, stderr: String)

    private let run: Runner

    public init(run: @escaping Runner) {
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

    /// The bearer token of the CLI's login. The CLI also prints it to stderr, so a
    /// failure carries neither stream.
    public func accessToken() async throws -> String {
        let result = try await run(["login", "print-access-token"], { _ in })
        if result.status == 127 { throw ViamCLIError.notInstalled }
        if result.status != 0 {
            throw Self.isLoggedOut(result.stderr) ? ViamCLIError.notLoggedIn : ViamCLIError.tokenUnavailable
        }
        guard let token = Self.lastLine(result.stdout) else { throw ViamCLIError.notLoggedIn }
        return token
    }

    /// The signed-in account, as the CLI names it.
    public func whoami() async throws -> String {
        guard let account = Self.lastLine(try await succeed(["whoami"])) else { throw ViamCLIError.notLoggedIn }
        return account
    }

    /// Signs in through the browser. `onCode` gets the device code as Viam's
    /// device-login page shows it, for the user to match. Cancelling the task stops
    /// the CLI.
    public func login(onCode: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        _ = try await succeed(["login"]) { line in
            if let code = Self.deviceCode(in: line) { onCode(code) }
        }
    }

    /// The `user_code` of the device URL the CLI prints, hyphenated at its middle
    /// as the device-login page shows it ("MYL9Y4" is shown "MYL-9Y4").
    static func deviceCode(in line: String) -> String? {
        let text = line.replacing(/\u{1B}\[[0-9;]*m/, with: "").trimmingCharacters(in: .whitespaces)
        guard let code = URLComponents(string: text)?.queryItems?.first(where: { $0.name == "user_code" })?.value,
              !code.isEmpty else { return nil }
        guard code.count.isMultiple(of: 2), !code.contains("-") else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle])-\(code[middle...])"
    }

    public func logout() async throws {
        _ = try await succeed(["logout"])
    }

    private func succeed(_ arguments: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let result = try await run(arguments, onLine)
        if result.status == 127 { throw ViamCLIError.notInstalled }
        guard result.status != 0 else { return result.stdout }
        if Self.isLoggedOut(result.stderr) { throw ViamCLIError.notLoggedIn }
        throw ViamCLIError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isLoggedOut(_ stderr: String) -> Bool {
        let stderr = stderr.lowercased()
        return stderr.contains("not logged in") || stderr.contains("log in again") || stderr.contains("viam login")
    }

    private static func lastLine(_ text: String) -> String? {
        lines(text).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// Lines with ANSI color codes removed; the CLI colors its prefixes on a terminal.
    private static func lines(_ text: String) -> [String] {
        text.replacing(/\u{1B}\[[0-9;]*m/, with: "").components(separatedBy: .newlines)
    }

    /// Where `viam` is installed. An app opened from Finder has a minimal PATH, so
    /// the usual install locations come first, then the user's login shell.
    public static func locate(
        fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        home: String = NSHomeDirectory(),
        shellLookup: () async -> String? = ViamCLI.loginShellLookup
    ) async -> URL? {
        let candidates = ["/opt/homebrew/bin/viam", "/usr/local/bin/viam", "\(home)/.local/bin/viam", "\(home)/bin/viam"]
        if let path = candidates.first(where: fileExists) { return URL(filePath: path) }
        guard let answer = await shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              answer.hasPrefix("/"), fileExists(answer) else { return nil }
        return URL(filePath: answer)
    }

    /// `command -v viam` in the user's login shell, so its PATH setup applies.
    public static let loginShellLookup: @Sendable () async -> String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await processRunner(executable: URL(filePath: shell))(["-l", "-c", "command -v viam"], { _ in }),
              result.status == 0 else { return nil }
        return result.stdout
    }

    /// Runs `executable`. Cancelling the calling task terminates the child. An
    /// executable that can't be launched counts as not installed.
    public static func processRunner(executable: URL) -> Runner {
        { arguments, onLine in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            let exit = ExitSignal()
            process.terminationHandler = { _ in exit.signal() }
            do {
                try process.run()
            } catch {
                throw ViamCLIError.notInstalled
            }
            return await withTaskCancellationHandler {
                async let out = readToEnd(stdout.fileHandleForReading, onLine: onLine)
                async let err = readToEnd(stderr.fileHandleForReading, onLine: nil)
                let (outData, errData) = await (out, err)
                // Cancellation must not end this wait: `terminationStatus` raises
                // while the child is still running.
                await exit.wait()
                return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
            } onCancel: {
                process.terminate()
            }
        }
    }

    /// Blocks a dispatch thread, not one of the cooperative pool's: `viam login`
    /// can hold its pipes open for minutes. `onLine` gets each complete line.
    private static func readToEnd(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)?) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var all = Data()
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    all.append(chunk)
                    guard let onLine else { continue }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                continuation.resume(returning: all)
            }
        }
    }
}

/// A one-shot signal from `Process.terminationHandler`, which may fire before
/// anyone waits. Waiting isn't cut short by cancellation.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        let waiter = lock.withLock {
            exited = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if exited { return true }
                waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }
}
