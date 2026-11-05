import Foundation
import Logging
import ProvisionerAPI
@testable import ProvisionerKit
@testable import ProvisionerServer
import Testing

let testLogger = Logger(label: "ProvisionerServerTests")

private func progress(_ name: String) -> (Int) -> Components.Schemas.MachineEvent {
    { id in .installProgress(.init(id: id, _type: .installProgress, timestamp: t0, name: name, stage: .tooling)) }
}

@Test func idsAreMonotonicAcrossReopen() throws {
    let url = try temporaryDirectory().appending(path: "events.jsonl")
    let journal = try EventJournal(url: url, logger: testLogger)
    #expect(journal.append(progress("a"))?.id == 1)
    #expect(journal.append(progress("b"))?.id == 2)

    let reopened = try EventJournal(url: url, logger: testLogger)
    #expect(reopened.lastID == 2)
    #expect(reopened.firstID == 1)
    #expect(reopened.append(progress("c"))?.id == 3)
}

@Test func eventsAfter() throws {
    let journal = try EventJournal(url: try temporaryDirectory().appending(path: "events.jsonl"), logger: testLogger)
    for name in ["a", "b", "c"] { _ = journal.append(progress(name)) }

    #expect(journal.events(after: 1).map(\.id) == [2, 3])
    #expect(journal.events(after: 3).isEmpty)
}

@Test func unwritableJournalLogsAndReturnsNil() throws {
    let url = try temporaryDirectory().appending(path: "events.jsonl")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let journal = try EventJournal(url: url, logger: testLogger)

    #expect(journal.append(progress("a")) == nil)
    #expect(journal.lastID == 0)
}

@Test func lineIsContractJSON() throws {
    let url = try temporaryDirectory().appending(path: "events.jsonl")
    let journal = try EventJournal(url: url, logger: testLogger)
    _ = journal.append(progress("m-1"))

    let line = try #require(String(decoding: Data(contentsOf: url), as: UTF8.self).split(separator: "\n").first)
    let decoded = try WireCoding.decoder.decode(Components.Schemas.MachineEvent.self, from: Data(line.utf8))
    #expect(WireEvent(decoded) == .machine(.init(id: 1, timestamp: t0, name: "m-1", mac: nil, kind: .installProgress(stage: "tooling"))))
}

@Test func reopenSkipsGarbageAndRepeatedIDs() throws {
    let url = try temporaryDirectory().appending(path: "events.jsonl")
    let journal = try EventJournal(url: url, logger: testLogger)
    for name in ["a", "b"] { _ = journal.append(progress(name)) }
    let lines = try String(decoding: Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
    let tampered = [String(lines[0]), "not json", String(lines[0]), String(lines[1])].joined(separator: "\n") + "\n"
    try Data(tampered.utf8).write(to: url)

    let reopened = try EventJournal(url: url, logger: testLogger)

    #expect(reopened.events(after: 0).map(\.id) == [1, 2])
    #expect(reopened.append(progress("c"))?.id == 3)
}
