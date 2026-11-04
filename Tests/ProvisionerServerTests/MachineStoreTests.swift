import Foundation
@testable import ProvisionerServer
import Testing

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ps-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
}

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

@Test func roundTrip() throws {
    let dir = DataDirectory(try temporaryDirectory())
    let store = try MachineStore(dir)
    let queue = [QueueRecord(name: "Robot-1", addedAt: t0), QueueRecord(name: "robot-2", addedAt: t0)]
    let machine = MachineRecord(attempt: 2, stage: "tooling", attemptStartedAt: t0, progressAt: t0.addingTimeInterval(5),
                                completedAt: nil, failedAt: nil, failureReason: nil, failureSource: nil)
    try store.save(queue: queue)
    try store.save(machine: machine, key: "robot-1")

    let reopened = try MachineStore(dir)
    #expect(reopened.queue == queue)
    #expect(reopened.machine("robot-1") == machine)
    #expect(reopened.machine("robot-2") == nil)
}

@Test func credentialModes() throws {
    let dir = DataDirectory(try temporaryDirectory())
    let store = try MachineStore(dir)
    try store.stage(credentials: Data(#"{"cloud":{"id":"i","secret":"s"}}"#.utf8), environment: Data("{}".utf8), key: "m-1")

    let folder = dir.credentials("m-1")
    #expect(try posixMode(folder.appending(path: "viam.json")) == 0o600)
    #expect(try posixMode(folder.appending(path: "environment.json")) == 0o600)
    #expect(try posixMode(folder) == 0o700)
    #expect(try posixMode(dir.root.appending(path: "credentials")) == 0o700)
    #expect(store.hasCredentials("m-1"))
    #expect(!store.hasCredentials("m-2"))
}

@Test func environmentAloneIsNotCredentials() throws {
    let dir = DataDirectory(try temporaryDirectory())
    let store = try MachineStore(dir)
    try store.stage(credentials: nil, environment: Data("{}".utf8), key: "m-1")

    #expect(!store.hasCredentials("m-1"))
}

@Test func corruptQueue() throws {
    let dir = DataDirectory(try temporaryDirectory())
    try dir.prepare()
    try Data("{".utf8).write(to: dir.queue)

    #expect(throws: StoreError.self) { try MachineStore(dir) }
    do {
        _ = try MachineStore(dir)
    } catch .queueUnreadable {
    } catch {
        Issue.record("expected queueUnreadable, got \(error)")
    }
}

@Test func atomicWriteLeavesNoTemp() throws {
    let dir = DataDirectory(try temporaryDirectory())
    let store = try MachineStore(dir)
    try store.save(queue: [QueueRecord(name: "a", addedAt: t0)])
    try store.save(queue: [QueueRecord(name: "a", addedAt: t0), QueueRecord(name: "b", addedAt: t0)])

    let names = try FileManager.default.contentsOfDirectory(atPath: dir.root.path).sorted()
    #expect(names == ["credentials", "machines", "queue.json"])
}

@Test func removeDeletesEverything() throws {
    let dir = DataDirectory(try temporaryDirectory())
    let store = try MachineStore(dir)
    try store.save(machine: MachineRecord(), key: "m-1")
    try store.stage(credentials: Data("{}".utf8), environment: nil, key: "m-1")

    try store.remove(key: "m-1")

    #expect(store.machine("m-1") == nil)
    #expect(!FileManager.default.fileExists(atPath: dir.machine("m-1").path))
    #expect(!FileManager.default.fileExists(atPath: dir.credentials("m-1").path))
    #expect(try MachineStore(dir).machine("m-1") == nil)
}
