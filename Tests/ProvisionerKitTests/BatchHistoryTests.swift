import Foundation
@testable import ProvisionerKit
import Testing

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "batches-\(UUID().uuidString)/batches.json")
}

private func record(_ machines: [String], at seconds: TimeInterval) -> BatchRecord {
    BatchRecord(id: UUID(), date: Date(timeIntervalSince1970: seconds), environmentName: "Lab", mode: .full,
                orgName: "Acme", locationName: "Bench", serverName: "bench", serverURL: URL(string: "http://10.0.0.2:8235/")!,
                machines: machines, problems: [])
}

@MainActor
struct BatchHistoryTests {
    @Test func recordsPersistNewestFirst() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let older = record(["lab-1"], at: 100)
        let newer = record(["lab-2"], at: 200)

        let history = BatchHistory(file: file)
        history.load()
        try history.save(older)
        try history.save(newer)

        let reopened = BatchHistory(file: file)
        reopened.load()
        #expect(reopened.records == [newer, older])
    }

    @Test func savingAKnownRecordReplacesIt() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var batch = record(["lab-1"], at: 100)
        let history = BatchHistory(file: file)
        history.load()
        try history.save(batch)

        batch.machines.append("lab-2")
        try history.save(batch)

        #expect(history.records == [batch])
    }

    @Test func unreadableFileIsReportedAndNeverOverwritten() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let history = BatchHistory(file: file)
        history.load()

        #expect(history.loadError != nil)
        #expect(throws: (any Error).self) { try history.save(record(["lab-1"], at: 100)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }

    @Test func loadSortsAFileWrittenInAnyOrder() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let older = record(["lab-1"], at: 100)
        let newer = record(["lab-2"], at: 200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([older, newer]).write(to: file)

        let history = BatchHistory(file: file)
        history.load()

        #expect(history.records == [newer, older])
    }

    @Test func loadErrorClearsOnceTheFileReads() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let history = BatchHistory(file: file)
        history.load()

        try Data("[]".utf8).write(to: file)
        history.load()

        #expect(history.loadError == nil)
    }

    @Test(arguments: [(ProvisionMode.full, "Acme", "Bench"), (.agent, nil, nil), (.osOnly, nil, nil)] as [(ProvisionMode, String?, String?)])
    func recordKeepsTheOrgOnlyForFullMode(mode: ProvisionMode, org: String?, location: String?) {
        var environment = Environment.new(name: "Lab")
        environment.provisionMode = mode
        environment.orgName = "Acme"
        environment.locationName = "Bench"

        let batch = BatchRecord(environment: environment, outcome: BatchOutcome(),
                                server: DiscoveredServer(name: "bench", baseURL: URL(string: "http://10.0.0.2:8235/")!), date: .now)

        #expect(batch.orgName == org && batch.locationName == location)
    }

    @Test func recordOfARunListsQueuedNamesAndWhatWentWrong() {
        var outcome = BatchOutcome()
        outcome.queued = ["lab-1"]
        outcome.viamFailures = [MachineFailure(name: "lab-2", message: "no main part", machineID: "m-lab-2", leftInViam: true)]
        outcome.unqueued = [ProvisionedMachine(name: "lab-3", machineID: "m-lab-3", partID: "p", credentialsJSON: Data())]
        outcome.unsent = ["lab-3"]
        outcome.sendError = "connection refused"
        outcome.untried = ["lab-4"]
        var environment = Environment.new(name: "Lab")
        environment.orgName = "Acme"
        environment.locationName = "Bench"

        let batch = BatchRecord(
            environment: environment, outcome: outcome,
            server: DiscoveredServer(name: "bench", baseURL: URL(string: "http://10.0.0.2:8235/")!), date: .now)

        #expect(batch.machines == ["lab-1"])
        #expect(batch.problems == [
            "lab-2 wasn't created: no main part. It may remain in Viam.",
            "lab-3 wasn't queued: connection refused. It was created in Viam.",
            "lab-4 wasn't tried.",
        ])
    }
}
