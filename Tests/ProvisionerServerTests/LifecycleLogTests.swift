import Foundation
import Logging
import ProvisionerLog
@testable import ProvisionerServer
import Testing

/// Captures each line with its category, as the platform log would record it.
private final class CategorizedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [LogLine] = []

    var lines: [LogLine] { lock.withLock { captured } }

    func logger(_ category: String) -> Logger {
        Logger(label: category) { _ in Handler(log: self, category: category) }
    }

    private struct Handler: LogHandler {
        let log: CategorizedLog
        let category: String
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let line = LogLine(date: Date(), level: event.level, category: category,
                               message: event.message.description, processID: getpid())
            log.lock.withLock { log.captured.append(line) }
        }
    }
}

@Test func aServerThatCantStartLogsTheErrorTheAppReads() async throws {
    let log = CategorizedLog()
    let status = await ServerMain.run(arguments: ["--bogus"], makeLogger: log.logger)
    #expect(status == 64)
    #expect(ServerLifecycle.startupError(in: log.lines) == "unknown option --bogus")
}

@Test func aServerThatStoppedOnAnUnusableDataDirectoryLogsThatError() async throws {
    let log = CategorizedLog()
    let files = try temporaryDirectory()
    let blocker = try temporaryDirectory().appendingPathComponent("file")
    try Data().write(to: blocker)
    let status = await ServerMain.run(arguments: ["--files", files.path, "--data-dir", blocker.appendingPathComponent("data").path,
                                                  "--port", "0", "--pxe-interface", "lo0"], makeLogger: log.logger)
    #expect(status == 1, "\(log.lines.map(\.message))")
    #expect(log.lines.first?.message == ServerLifecycle.launched)
    #expect(ServerLifecycle.startupError(in: log.lines) != nil)
}
