import Foundation
import Logging
import Testing
@testable import ProvisionerLog

#if canImport(OSLog)
@Test func logStreamNDJSONLineParses() throws {
    let json = #"{"messageType":"Error","category":"pxe","subsystem":"com.bringingfire.viam-provisioner","timestamp":"2026-11-19 13:23:08.253510-0500","eventMessage":"TFTP failed","processID":1999}"#
    let parsed = try #require(UnifiedLogFormat.line(fromNDJSON: json))
    #expect(parsed.level == .error)
    #expect(parsed.category == "pxe")
    #expect(parsed.message == "TFTP failed")
    #expect(parsed.processID == 1999)
    #expect(abs(parsed.date.timeIntervalSince1970 - 1_795_112_588.25351) < 0.001)
}

@Test func logStreamBannerIsNotALine() {
    #expect(UnifiedLogFormat.line(fromNDJSON: #"Filtering the log data using "subsystem == "x"""#) == nil)
}

@Test func unifiedLogLevelsRoundTripAtTheirPersistedLevel() {
    // Info and notice both persist as Default, so they read back as notice; warning reads back as error.
    let expected: [(Logger.Level, Logger.Level)] = [
        (.trace, .debug), (.debug, .debug), (.info, .notice), (.notice, .notice),
        (.warning, .error), (.error, .error), (.critical, .critical),
    ]
    for (written, read) in expected {
        #expect(UnifiedLogFormat.level(messageType: UnifiedLogFormat.messageType(for: written)) == read)
    }
}

#endif

@Test func journalJSONLineParses() throws {
    let json = #"{"__REALTIME_TIMESTAMP":"1795112588253510","PRIORITY":"3","_PID":"42","MESSAGE":"pxe: TFTP failed","SYSLOG_IDENTIFIER":"provisioner-server"}"#
    let parsed = try #require(JournalFormat.line(fromJSON: json))
    #expect(parsed.level == .error)
    #expect(parsed.category == "pxe")
    #expect(parsed.message == "TFTP failed")
    #expect(parsed.processID == 42)
    #expect(abs(parsed.date.timeIntervalSince1970 - 1_795_112_588.25351) < 0.001)
}

@Test func journalHandlerPrefixesSyslogPriorityAndCategory() {
    #expect(JournalFormat.render(level: .critical, category: "lifecycle", message: "stopped: x\nusage") == "<2>lifecycle: stopped: x usage\n")
}

@Test func chunkedOutputSplitsIntoWholeLines() {
    var splitter = LineSplitter()
    #expect(splitter.append(Data("one\ntw".utf8)) == ["one"])
    #expect(splitter.append(Data("o\nthree\n".utf8)) == ["two", "three"])
    #expect(splitter.finish() == nil)
}
