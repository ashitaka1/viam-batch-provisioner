import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

typealias Schemas = Components.Schemas

let t0 = Date(timeIntervalSince1970: 1_790_000_000)

func makeProvisioner(_ root: URL? = nil, now: @escaping @Sendable () -> Date = { t0 }) throws -> (Provisioner, DataDirectory) {
    let dir = DataDirectory(try root ?? temporaryDirectory())
    return (try Provisioner(dataDirectory: dir, now: now, logger: testLogger), dir)
}

func request(_ name: String, credentials: Schemas.ViamCredentials? = nil,
             environment: Schemas.Environment? = nil) -> Schemas.ProvisionRequest {
    .init(name: name, credentials: credentials, environment: environment)
}

func creds(_ id: String) -> Schemas.ViamCredentials {
    .init(cloud: .init(id: id, secret: "secret-\(id)"))
}

private func outcome(_ results: [Schemas.ProvisionResult]) -> [String] {
    results.map { [$0.name, $0.result.rawValue, $0.reason?.rawValue].compactMap { $0 }.joined(separator: " ") }
}

@Test func provisionAddsAndSkips() async throws {
    let (provisioner, _) = try makeProvisioner()

    let first = try await provisioner.provision([request("a-1"), request("a-2")])
    let second = try await provisioner.provision([request("a-2"), request("a-3"), request("a-3")])

    #expect(outcome(first) == ["a-1 added", "a-2 added"])
    #expect(outcome(second) == ["a-2 skipped already-queued", "a-3 added", "a-3 skipped duplicate-in-request"])
    #expect(try await provisioner.snapshot().entries.map(\.name) == ["a-1", "a-2", "a-3"])
}

@Test func caseVariantIsAlreadyQueued() async throws {
    let (provisioner, _) = try makeProvisioner()
    _ = try await provisioner.provision([request("robot-1")])

    let results = try await provisioner.provision([request("Robot-1")])

    #expect(outcome(results) == ["Robot-1 skipped already-queued"])
    #expect(try await provisioner.entry("ROBOT-1").name == "robot-1")
}

@Test func invalidItemRejectsWholeRequest() async throws {
    let (provisioner, _) = try makeProvisioner()

    guard case .invalid(_, let details) = await failure({ try await provisioner.provision([request("ok-1"), request("-bad")]) }) else {
        Issue.record("expected the request to be rejected as invalid")
        return
    }
    #expect(details.map(\.index) == [1])
    #expect(details.map(\.field) == ["name"])
    #expect(try await provisioner.snapshot().entries.isEmpty)
}

@Test func emptyCredentialIDRejected() async throws {
    let (provisioner, _) = try makeProvisioner()

    let result = await failure { try await provisioner.provision([request("m-1", credentials: .init(cloud: .init(id: "", secret: "s")))]) }
    #expect(result?.kind == "invalid")
}

@Test func credentialsNeverOverwritten() async throws {
    let (provisioner, dir) = try makeProvisioner()
    _ = try await provisioner.provision([request("m-1", credentials: creds("A"))])
    _ = try await provisioner.provision([request("m-1", credentials: creds("B"))])

    let stored = try JSONDecoder().decode(Schemas.ViamCredentials.self,
                                          from: Data(contentsOf: dir.credentials("m-1").appending(path: "viam.json")))
    #expect(stored.cloud.id == "A")
    #expect(try await provisioner.entry("m-1").hasCredentials)
}

@Test func environmentStored() async throws {
    let (provisioner, dir) = try makeProvisioner()
    let environment = Schemas.Environment(provisionMode: .full, username: "viam", passwordHash: "$6$x$y",
                                          sshPublicKey: "ssh-ed25519 AAAA", timezone: "UTC")
    _ = try await provisioner.provision([request("m-1", environment: environment)])

    let stored = try JSONDecoder().decode(Schemas.Environment.self,
                                          from: Data(contentsOf: dir.credentials("m-1").appending(path: "environment.json")))
    #expect(stored == environment)
    #expect(try await !provisioner.entry("m-1").hasCredentials)
}

@Test func concurrentProvisionLosesNothing() async throws {
    let (provisioner, _) = try makeProvisioner()

    let added = try await withThrowingTaskGroup(of: [Schemas.ProvisionResult].self) { group in
        for i in 0..<20 {
            group.addTask { try await provisioner.provision([request("c-\(i)"), request("shared")]) }
        }
        return try await group.reduce(into: []) { $0 += $1 }
    }

    let entries = try await provisioner.snapshot().entries
    #expect(entries.count == 21)
    #expect(added.filter { $0.name == "shared" && $0.result == .added }.count == 1)
}

/// Records for each status are written to the store before the Provisioner
/// opens it: install reports arrive in a later task, and the store is the seam.
@Test func removeRules() async throws {
    let root = try temporaryDirectory()
    let store = try MachineStore(DataDirectory(root))
    try store.save(queue: ["q-1", "i-1", "d-1", "f-1"].map { QueueRecord(name: $0, addedAt: t0) })
    try store.save(machine: MachineRecord(attempt: 1, stage: "tooling", attemptStartedAt: t0), key: "i-1")
    try store.save(machine: MachineRecord(attempt: 1, stage: "done", attemptStartedAt: t0, completedAt: t0), key: "d-1")
    try store.save(machine: MachineRecord(attempt: 1, stage: "tooling", attemptStartedAt: t0, failedAt: t0,
                                          failureReason: "r", failureSource: "installer"), key: "f-1")
    let (provisioner, dir) = try makeProvisioner(root)

    try await provisioner.remove("q-1")
    await #expect(throws: ProvisionerFailure.alreadyAssigned("i-1")) { try await provisioner.remove("i-1") }
    try await provisioner.remove("d-1")
    try await provisioner.remove("f-1")

    #expect(try await provisioner.snapshot().entries.map(\.name) == ["i-1"])
    #expect(!FileManager.default.fileExists(atPath: dir.machine("d-1").path))
    #expect(outcome(try await provisioner.provision([request("d-1")])) == ["d-1 added"])
    #expect(try await provisioner.entry("d-1").status == .queued)
}

@Test func statusesDerive() async throws {
    let root = try temporaryDirectory()
    let store = try MachineStore(DataDirectory(root))
    try store.save(queue: ["q-1", "i-1", "d-1", "f-1"].map { QueueRecord(name: $0, addedAt: t0) })
    try store.save(machine: MachineRecord(attempt: 1, stage: "tooling", attemptStartedAt: t0), key: "i-1")
    try store.save(machine: MachineRecord(attempt: 1, stage: "done", attemptStartedAt: t0, completedAt: t0), key: "d-1")
    try store.save(machine: MachineRecord(attempt: 1, stage: "done", attemptStartedAt: t0, completedAt: t0, failedAt: t0,
                                          failureReason: "r", failureSource: "installer"), key: "f-1")
    let (provisioner, _) = try makeProvisioner(root)

    let entries = try await provisioner.snapshot().entries
    #expect(entries.map(\.status) == [.queued, .installing, .installed, .failed])
    #expect(entries[1].stage == .tooling)
    #expect(entries[3].failureReason == "r")
    #expect(await provisioner.counts() == .init(queued: 1, flashed: 0, assigned: 0, installing: 1, installed: 1, failed: 1, total: 4))
}

@Test func unknownEntryIsNotFound() async throws {
    let (provisioner, _) = try makeProvisioner()

    await #expect(throws: ProvisionerFailure.notFound("nope")) { try await provisioner.entry("nope") }
    await #expect(throws: ProvisionerFailure.notFound("nope")) { try await provisioner.remove("nope") }
}

@Test(arguments: ["../x", "a b", String(repeating: "a", count: 61)])
func invalidLookupName(name: String) async throws {
    let (provisioner, _) = try makeProvisioner()

    #expect(await failure { try await provisioner.entry(name) }?.kind == "invalidName")
    #expect(await failure { try await provisioner.remove(name) }?.kind == "invalidName")
}

@Test func emptyRequestRejected() async throws {
    let (provisioner, _) = try makeProvisioner()

    #expect(await failure { try await provisioner.provision([]) }?.kind == "invalid")
}

@Test func requestSizeLimit() async throws {
    let (provisioner, _) = try makeProvisioner()

    #expect(await failure { try await provisioner.provision((0...500).map { request("big-\($0)") }) }?.kind == "invalid")
    #expect(try await provisioner.provision((0..<500).map { request("big-\($0)") }).count == 500)
}

@Test func stagingFailureQueuesNothing() async throws {
    let (provisioner, dir) = try makeProvisioner()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.credentialsRoot.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.credentialsRoot.path) }

    let result = await failure { try await provisioner.provision([request("m-1"), request("m-2", credentials: creds("B"))]) }

    #expect(result?.kind == "internal")
    #expect(try await provisioner.snapshot().entries.isEmpty)
}

@Test func unreadableQueue() async throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: DataDirectory(root).queue)
    let (provisioner, _) = try makeProvisioner(root)

    #expect(await failure { try await provisioner.snapshot() }?.kind == "queueUnreadable")
    #expect(await provisioner.counts() == nil)
}

@Test func snapshotCarriesLastEventID() async throws {
    let root = try temporaryDirectory()
    let journal = try EventJournal(url: DataDirectory(root).journal, logger: testLogger)
    for _ in 0..<3 {
        _ = journal.append { .installProgress(.init(id: $0, _type: .installProgress, timestamp: t0, name: "x", stage: .tooling)) }
    }
    let (provisioner, _) = try makeProvisioner(root)

    #expect(try await provisioner.snapshot().lastEventID == 3)
}

@Test func leftoverCredentialsNeverReachANewEntry() async throws {
    let (provisioner, dir) = try makeProvisioner()
    try FileManager.default.createDirectory(at: dir.credentials("m-1"), withIntermediateDirectories: true)
    try Data(#"{"cloud":{"id":"old","secret":"old"}}"#.utf8).write(to: dir.credentials("m-1").appending(path: "viam.json"))

    _ = try await provisioner.provision([request("m-1")])

    #expect(try await !provisioner.entry("m-1").hasCredentials)
    #expect(!FileManager.default.fileExists(atPath: dir.credentials("m-1").appending(path: "viam.json").path))
}

@Test func leftoverRecordNeverReachesANewEntry() async throws {
    let root = try temporaryDirectory()
    try MachineStore(DataDirectory(root)).save(machine: MachineRecord(attempt: 1, stage: "done", completedAt: t0), key: "m-1")
    let (provisioner, _) = try makeProvisioner(root)

    _ = try await provisioner.provision([request("m-1")])

    #expect(try await provisioner.entry("m-1").status == .queued)
}
