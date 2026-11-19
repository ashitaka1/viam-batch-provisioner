import Foundation
import ProvisionerLog

/// `ViamProvisioner --server-log [startup-error]`: reads the server's log as the logged-in user and exits
/// before any window opens. With no action it prints the last hour and follows new lines until interrupted;
/// `startup-error` prints the error that stopped the server's latest launch, or nothing.
enum ServerLogCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--server-log") else { return }
        let next = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        // A following flag, such as one Xcode appends, isn't an action.
        let action = next.hasPrefix("-") ? "" : next
        // Followed lines reach a pipe or file as they arrive, not when the buffer fills.
        setvbuf(stdout, nil, _IOLBF, 0)
        let reader = ProvisionerLog.reader()
        let finished = DispatchSemaphore(value: 0)
        let status = Status()
        Task.detached {
            do {
                switch action {
                case "":
                    // Following starts first, so no line falls between the two reads; a line both return
                    // prints once.
                    let followed = reader.follow()
                    let history = try await reader.history(since: Date().addingTimeInterval(-3600))
                    for line in history { print(format(line)) }
                    let last = history.last?.date ?? .distantPast
                    for try await line in followed where line.date > last { print(format(line)) }
                case "startup-error":
                    let lines = try await reader.history(since: Date().addingTimeInterval(-86_400))
                    if let error = ServerLifecycle.startupError(in: lines) { print(error) }
                default:
                    status.fail("--server-log takes no action or startup-error.")
                }
            } catch {
                status.fail("Can't read the server's log: \(error)")
            }
            finished.signal()
        }
        finished.wait()
        exit(status.code)
    }

    static func format(_ line: LogLine) -> String {
        "\(line.date.formatted(.iso8601)) \(line.level) \(line.category): \(line.message)"
    }

    private final class Status: @unchecked Sendable {
        private(set) var code: Int32 = 0

        func fail(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            code = 1
        }
    }
}
