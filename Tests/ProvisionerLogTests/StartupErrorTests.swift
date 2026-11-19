import Foundation
import Logging
import Testing
@testable import ProvisionerLog

private func line(_ seconds: Double, _ level: Logger.Level, _ category: String, _ message: String, pid: Int32 = 1) -> LogLine {
    LogLine(date: Date(timeIntervalSince1970: seconds), level: level, category: category, message: message, processID: pid)
}

@Test func startupErrorIsTheStopRecordedAfterTheLatestLaunch() {
    let lines = [
        line(1, .notice, ServerLifecycle.category, ServerLifecycle.launched, pid: 10),
        line(2, .critical, ServerLifecycle.category, ServerLifecycle.stoppedPrefix + "old failure", pid: 10),
        line(3, .notice, ServerLifecycle.category, ServerLifecycle.launched, pid: 11),
        line(4, .notice, "http", "GET /api/v1/status 200", pid: 11),
        line(5, .critical, ServerLifecycle.category, ServerLifecycle.stoppedPrefix + "Address already in use", pid: 11),
    ]
    #expect(ServerLifecycle.startupError(in: lines) == "Address already in use")
}

@Test func aLaunchAfterTheLastStopHasNoStartupErrorYet() {
    let lines = [
        line(1, .notice, ServerLifecycle.category, ServerLifecycle.launched, pid: 10),
        line(2, .critical, ServerLifecycle.category, ServerLifecycle.stoppedPrefix + "old failure", pid: 10),
        line(3, .notice, ServerLifecycle.category, ServerLifecycle.launched, pid: 11),
    ]
    #expect(ServerLifecycle.startupError(in: lines) == nil)
}

@Test func aStopWithoutARecordedLaunchStillCounts() {
    // History that starts after the launch line still reports the failure that follows it.
    let lines = [line(2, .critical, ServerLifecycle.category, ServerLifecycle.stoppedPrefix + "no such directory")]
    #expect(ServerLifecycle.startupError(in: lines) == "no such directory")
}

@Test func aStopFromAnotherProcessDoesNotCountForTheLatestLaunch() {
    let lines = [
        line(1, .notice, ServerLifecycle.category, ServerLifecycle.launched, pid: 10),
        line(2, .critical, ServerLifecycle.category, ServerLifecycle.stoppedPrefix + "unknown option --bogus", pid: 11),
    ]
    #expect(ServerLifecycle.startupError(in: lines) == nil)
}
