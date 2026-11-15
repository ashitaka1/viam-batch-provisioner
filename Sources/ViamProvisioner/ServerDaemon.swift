import Foundation
import Observation
import ProvisionerKit
import ServiceManagement

/// A launch daemon the app registers: `SMAppService` in the app, a fake in tests.
protocol DaemonService: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: DaemonService {}

enum ServerDaemonState: Equatable {
    case off, on, needsApproval, missing

    /// SMAppService reports `.notFound` for a daemon that was never registered as well as for one the
    /// bundle lacks, so only `bundled` tells them apart.
    init(_ status: SMAppService.Status, bundled: Bool) {
        switch status {
        case .enabled: self = .on
        case .requiresApproval: self = .needsApproval
        case _ where !bundled: self = .missing
        default: self = .off
        }
    }
}

enum PrivilegedScriptError: Error, Equatable {
    case cancelled
    case failed(String)

    init(appleScriptError error: NSDictionary) {
        if error[NSAppleScript.errorNumber] as? Int == -128 {
            self = .cancelled
        } else {
            self = .failed(error[NSAppleScript.errorMessage] as? String ?? "The administrator script failed.")
        }
    }
}

/// Server mode on this Mac (docs/decisions/0050): the ProvisionerServer launch daemon, and the
/// `_viamprovisioner` account and directory it runs with, which only an administrator can create or remove.
@MainActor @Observable final class ServerDaemon {
    private(set) var state: ServerDaemonState
    /// Why the last action didn't do what was asked.
    private(set) var note: String?
    /// Another user or group holding `_viamprovisioner`'s ID, as of the last refresh.
    private(set) var conflict: ServerAccount.IDConflict?
    /// Where `_viamprovisioner` can't reach the app's server binary, as of the last refresh; launchd can't start
    /// the daemon from such a copy of the app.
    private(set) var unreachablePath: URL?
    /// Whether the server answers, as of the last check; nil while hosting is off or before the first check.
    private(set) var serving: ServerServing?

    var notAnsweringMessage: String? {
        guard case .notAnswering(let reason) = serving else { return nil }
        return ["The server isn't answering.", reason].compactMap { $0 }.joined(separator: " ")
    }

    /// Hosting is on, but launchd can't start the server from this copy of the app.
    var cantStart: Bool {
        unreachablePath != nil && (state == .on || state == .needsApproval)
    }

    var unreachableMessage: String? {
        guard let path = unreachablePath?.path else { return nil }
        return cantStart
            ? "The server can't start: it runs as \(ServerAccount.name), which can't open \(path). Move Viam Provisioner to the Applications folder."
            : "Move Viam Provisioner to the Applications folder to turn on server mode. The server runs as \(ServerAccount.name), which can't open \(path)."
    }

    private let service: any DaemonService
    private let isBundled: @Sendable () -> Bool
    private let isSetUp: @Sendable () -> Bool
    private let readUnreachablePath: @Sendable () -> URL?
    private let readConflict: @Sendable () -> ServerAccount.IDConflict?
    private let runPrivileged: @Sendable (String) async throws -> Void
    private let askServer: @Sendable () async -> ServerAnswer
    private let readJob: @Sendable () async -> LaunchdJob?

    init(service: any DaemonService, isBundled: @escaping @Sendable () -> Bool, isSetUp: @escaping @Sendable () -> Bool,
         unreachablePath: @escaping @Sendable () -> URL?,
         conflict: @escaping @Sendable () -> ServerAccount.IDConflict?,
         runPrivileged: @escaping @Sendable (String) async throws -> Void,
         askServer: @escaping @Sendable () async -> ServerAnswer,
         readJob: @escaping @Sendable () async -> LaunchdJob?) {
        self.service = service
        self.isBundled = isBundled
        self.isSetUp = isSetUp
        readUnreachablePath = unreachablePath
        readConflict = conflict
        self.runPrivileged = runPrivileged
        self.askServer = askServer
        self.readJob = readJob
        state = ServerDaemonState(service.status, bundled: isBundled())
        self.unreachablePath = unreachablePath()
        self.conflict = conflict()
    }

    func refresh() {
        state = ServerDaemonState(service.status, bundled: isBundled())
        unreachablePath = readUnreachablePath()
        conflict = readConflict()
        if state != .on { serving = nil }
    }

    private var checking = false

    /// Rereads the daemon's registration, then asks a registered server for its status. When it doesn't answer,
    /// the reason is what launchd recorded of its restarts and last exit, and whether another process holds the
    /// port. The account's conflict and the app's reachability are left to `refresh()`, which runs dscl.
    /// A check already under way makes this one return at once.
    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard readServing() else { return }
        let answer = await askServer()
        let job = answer == .answering ? nil : await readJob()
        // Hosting may have been turned off while the server was asked, or the view asking may have gone.
        guard !Task.isCancelled, readServing() else { return }
        switch answer {
        case .answering:
            serving = .answering
        case .silent, .otherProcess, .failing:
            let detail: String? = switch answer {
            case .otherProcess: "Another process answers on port \(ServerAccount.port)."
            case .failing(let message): "It answered: \(message)"
            default: nil
            }
            let reason = [detail, job?.reason].compactMap { $0 }.joined(separator: " ")
            serving = .notAnswering(reason: reason.isEmpty ? nil : reason)
        }
    }

    /// Updates `state`; false, clearing `serving`, when there's no server to ask: hosting is off, or launchd
    /// can't start it from this copy of the app, which `unreachableMessage` already says.
    private func readServing() -> Bool {
        state = ServerDaemonState(service.status, bundled: isBundled())
        guard state == .on, !cantStart else {
            serving = nil
            return false
        }
        return true
    }

    /// On: creates the account and directory when they're missing, then registers the daemon.
    /// Off: unregisters it, keeping the account and directory.
    func setHosting(_ on: Bool) async {
        note = nil
        defer { refresh() }
        guard on else {
            do { try await service.unregister() } catch { note = error.localizedDescription }
            return
        }
        if let unreachableMessage {
            note = unreachableMessage
            return
        }
        if !isSetUp() {
            guard await runScript(ServerAccount.createScript(), cancelled: "The server wasn't set up.") else { return }
        }
        do {
            try service.register()
        } catch where service.status == .requiresApproval {
            // register() throws while the daemon awaits approval in System Settings.
        } catch {
            note = error.localizedDescription
        }
    }

    /// Unregisters the daemon, then deletes the server directory and the account. The daemon goes first
    /// so launchd can't start the server against a half-removed account.
    func removeServerData() async {
        note = nil
        defer { refresh() }
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try await service.unregister()
            } catch {
                note = error.localizedDescription
                return
            }
        }
        _ = await runScript(ServerAccount.removeScript(), cancelled: "Server data and the _viamprovisioner account were kept.")
    }

    private func runScript(_ script: String, cancelled: String) async -> Bool {
        do {
            try await runPrivileged(script)
            return true
        } catch PrivilegedScriptError.cancelled {
            note = cancelled
        } catch PrivilegedScriptError.failed(let message) {
            note = message
        } catch {
            note = error.localizedDescription
        }
        return false
    }
}

extension ServerDaemon {
    nonisolated static let plistName = "\(ServerAccount.label).plist"

    static func app() -> ServerDaemon {
        ServerDaemon(service: SMAppService.daemon(plistName: plistName),
                     isBundled: {
                         FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                             .appending(path: "Contents/Library/LaunchDaemons/\(plistName)").path)
                     },
                     isSetUp: { ServerAccount.isSetUp() },
                     unreachablePath: {
                         ServerAccount.unreachablePath(to: Bundle.main.bundleURL.appending(path: "Contents/MacOS/provisioner-server"))
                     },
                     conflict: { ServerAccount.currentConflict() },
                     runPrivileged: runWithAdministratorPrivileges,
                     askServer: { await ServerAnswer.local() },
                     readJob: { await LaunchdJob.server() })
    }

    /// The AppleScript that runs `script` as root after macOS asks for an administrator's password.
    nonisolated static func appleScriptSource(for script: String) -> String {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Runs `script` as root after macOS asks for an administrator's password, which names the app.
    /// NSAppleScript isn't thread-safe, so it runs on the main actor, one script at a time.
    @MainActor static func runWithAdministratorPrivileges(_ script: String) async throws {
        var error: NSDictionary?
        if NSAppleScript(source: appleScriptSource(for: script))?.executeAndReturnError(&error) == nil, let error {
            throw PrivilegedScriptError(appleScriptError: error)
        }
    }
}
