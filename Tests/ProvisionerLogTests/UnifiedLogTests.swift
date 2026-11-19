#if canImport(OSLog)
import Foundation
import Logging
import OSLog
import Testing
@testable import ProvisionerLog

/// Reading the unified log takes an administrator account.
private let canReadUnifiedLog = (try? OSLogStore.local()) != nil

/// Each test writes under its own subsystem, so it reads back only its own lines.
private func testSubsystem() -> String { "com.bringingfire.viam-provisioner.test.\(UUID().uuidString)" }

@Test(.enabled(if: canReadUnifiedLog)) func historyReadsWrittenLinesInOrderWithTheirLevels() async throws {
    let subsystem = testSubsystem()
    let start = Date().addingTimeInterval(-1)
    let logger = Logger(label: "pxe") { UnifiedLogHandler(subsystem: subsystem, category: $0) }
    logger.info("PXE offer to aa:bb")
    logger.error("TFTP failed", metadata: ["file": "grubx64.efi"])
    logger.critical("stopped: boom")

    // The unified log flushes asynchronously, so read until all three lines are there.
    let reader = UnifiedLogReader(subsystem: subsystem)
    var lines: [LogLine] = []
    let deadline = ContinuousClock.now + .seconds(10)
    while lines.count < 3 && ContinuousClock.now < deadline {
        lines = try await reader.history(since: start)
        if lines.count < 3 { try await Task.sleep(for: .milliseconds(200)) }
    }
    #expect(lines.map(\.message) == ["PXE offer to aa:bb", "TFTP failed file=grubx64.efi", "stopped: boom"])
    #expect(lines.map(\.level) == [.notice, .error, .critical])
    #expect(lines.allSatisfy { $0.category == "pxe" && $0.processID == getpid() })
}

@Test(.enabled(if: canReadUnifiedLog)) func followDeliversLinesWrittenAfterItStarts() async throws {
    let subsystem = testSubsystem()
    let logger = Logger(label: "http") { UnifiedLogHandler(subsystem: subsystem, category: $0) }
    let stream = UnifiedLogReader(subsystem: subsystem).follow()
    // `log stream` attaches asynchronously, so write until it delivers.
    let writer = Task {
        while !Task.isCancelled {
            logger.info("GET /api/v1/status 200")
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    defer { writer.cancel() }
    let line = try await withThrowingTaskGroup(of: LogLine?.self) { group in
        group.addTask {
            for try await line in stream { return line }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(20))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
    let delivered = try #require(line)
    #expect(delivered.message == "GET /api/v1/status 200")
    #expect(delivered.category == "http")
}
#endif
