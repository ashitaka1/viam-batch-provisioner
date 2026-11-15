import Foundation
import ProvisionerKit

/// `ViamProvisioner --server-daemon register|unregister|remove|status`: drives `ServerDaemon` from the
/// app's own process, which SMAppService requires, and exits before any window opens.
enum ServerDaemonCommand {
    @MainActor static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--server-daemon") else { return }
        let action = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        let daemon = ServerDaemon.app()
        var finished = false
        Task { @MainActor in
            switch action {
            case "register": await daemon.setHosting(true)
            case "unregister": await daemon.setHosting(false)
            case "remove": await daemon.removeServerData()
            case "status": daemon.refresh()
            default: fail("--server-daemon takes register, unregister, remove or status.")
            }
            finished = true
        }
        // The task runs on the main actor, which the main run loop drains before the app starts.
        while !finished { RunLoop.main.run(mode: .default, before: .now.addingTimeInterval(0.1)) }
        let report = Self.report(state: daemon.state, note: daemon.note, conflict: daemon.conflict,
                            cantStart: daemon.cantStart ? daemon.unreachableMessage : nil)
        for line in report.errors { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        print(report.status)
        exit(report.exitCode)
    }

    struct Report: Equatable {
        let errors: [String]
        let status: String
        let exitCode: Int32
    }

    /// What the command prints and its exit code: 1 when the last action failed, another account shares the
    /// server account's ID, or hosting is on and the server can't start.
    static func report(state: ServerDaemonState, note: String?, conflict: ServerAccount.IDConflict?, cantStart: String?) -> Report {
        let errors = [note, conflict?.message, cantStart == note ? nil : cantStart].compactMap { $0 }
        return Report(errors: errors, status: "server daemon: \(describe(state))", exitCode: errors.isEmpty ? 0 : 1)
    }

    private static func describe(_ state: ServerDaemonState) -> String {
        switch state {
        case .off: "not registered"
        case .on: "enabled"
        case .needsApproval: "registered; turn it on under Background App Activity in System Settings > General > Login Items & Extensions"
        case .missing: "missing from the app bundle"
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
