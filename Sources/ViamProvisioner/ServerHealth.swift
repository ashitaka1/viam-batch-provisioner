import Foundation
import ProvisionerKit

/// What the server daemon's port gave back to `GET /api/v1/status`.
enum ServerAnswer: Equatable, Sendable {
    case answering
    /// Nothing answered: refused, timed out, or the connection dropped.
    case silent
    /// Something answered, but not with a status.
    case otherProcess
    /// The server answered with its error body.
    case failing(String)

    init(_ error: ProvisionerError) {
        switch error {
        case .transport: self = .silent
        case .server(_, _, let message, _): self = .failing(message)
        case .unexpectedResponse, .invalidCredentials: self = .otherProcess
        }
    }

    private static let localClient = ProvisionerClient(baseURL: URL(string: "http://127.0.0.1:\(ServerAccount.port)")!,
                                                       requestTimeout: 3)

    /// Asks the server on this Mac for its status.
    static func local() async -> ServerAnswer {
        do {
            _ = try await localClient.status()
            return .answering
        } catch {
            return ServerAnswer(error)
        }
    }
}

/// What launchd recorded about the server daemon's job.
struct LaunchdJob: Equatable, Sendable {
    var runs: Int?
    /// launchd's `last exit code`, nil while the job has never exited.
    var lastExitCode: String?
    var lastSignal: String?

    /// Reads the top-level fields of `launchctl print system/<label>`.
    init(launchctlPrint text: String) {
        func field(_ name: String) -> String? {
            // Top-level fields are indented one tab; nested blocks two or more.
            for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
                let trimmed = line.dropFirst()
                if trimmed.hasPrefix("\(name) = ") { return String(trimmed.dropFirst(name.count + 3)) }
            }
            return nil
        }
        runs = field("runs").flatMap { Int($0) }
        lastExitCode = field("last exit code").flatMap { $0.hasPrefix("(never") ? nil : $0 }
        lastSignal = field("last terminating signal")
    }

    init(runs: Int? = nil, lastExitCode: String? = nil, lastSignal: String? = nil) {
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.lastSignal = lastSignal
    }

    /// The restarts and the last exit, when launchd recorded one.
    var reason: String? {
        let exit: String? = if let lastSignal { "it was last stopped by \(lastSignal)" }
            else if let lastExitCode { "it last exited with code \(lastExitCode)" }
            else { nil }
        guard let exit else { return nil }
        guard let runs else { return "launchd says \(exit)." }
        return "launchd has started it \(runs) \(runs == 1 ? "time" : "times"); \(exit)."
    }

    /// Runs `launchctl print` for the server daemon, which needs no privileges.
    static func server() async -> LaunchdJob? {
        await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(filePath: "/bin/launchctl")
            process.arguments = ["print", "system/\(ServerAccount.label)"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return LaunchdJob(launchctlPrint: String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Whether the registered server answers on this Mac.
enum ServerServing: Equatable {
    case answering
    case notAnswering(reason: String?)
}
