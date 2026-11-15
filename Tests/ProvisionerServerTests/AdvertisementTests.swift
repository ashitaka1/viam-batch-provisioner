import Foundation
import Logging
import ServiceLifecycleTestKit
import Testing
@testable import ProvisionerServer

/// A publisher whose first `failures` publications fail and whose next one holds until cancelled.
private final class ScriptedPublisher: ServicePublisher, @unchecked Sendable {
    struct Failed: Error, CustomStringConvertible {
        var description: String { "mDNS daemon went away" }
    }

    private let lock = NSLock()
    private var remainingFailures: Int
    private var published: [ServiceRecord] = []
    private var cancelled = false

    init(failures: Int) { remainingFailures = failures }

    var records: [ServiceRecord] { lock.withLock { published } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func publish(_ record: ServiceRecord) async throws {
        let fails = lock.withLock {
            published.append(record)
            remainingFailures -= 1
            return remainingFailures >= 0
        }
        if fails { throw Failed() }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            lock.withLock { cancelled = true }
            throw error
        }
    }
}

/// A pause the test releases one step at a time.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, any Error>] = []

    var pausedCount: Int { lock.withLock { waiting.count } }

    func pause() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func release() { lock.withLock { waiting.removeFirst() }.resume() }
    func fail() { lock.withLock { waiting.removeFirst() }.resume(throwing: CancellationError()) }
}

private let record = ServiceRecord(name: "studio", port: 8234)

@Test(.timeLimit(.minutes(1)))
func advertisementPublishesAgainAfterAFailure() async throws {
    try await testGracefulShutdown { trigger in
        let publisher = ScriptedPublisher(failures: 1)
        let log = CapturedLog()
        let advertisement = Advertisement(record: record, publisher: publisher, logger: log.logger, pause: {})
        let running = Task { await advertisement.run() }
        defer { trigger.triggerGracefulShutdown() }

        try await poll(within: .seconds(2)) { publisher.records.count == 2 }

        #expect(publisher.records == [record, record])
        #expect(log.errors.contains { $0.contains("mDNS daemon went away") },
                "expected the failure logged, got \(log.errors)")
        trigger.triggerGracefulShutdown()
        await running.value
    }
}

@Test(.timeLimit(.minutes(1)))
func advertisementPausesBeforeEachRetry() async throws {
    let publisher = ScriptedPublisher(failures: 3)
    let gate = Gate()
    let advertisement = Advertisement(record: record, publisher: publisher, logger: Logger(label: "test"),
                                      pause: { try await gate.pause() })
    let running = Task { await advertisement.run() }

    try await poll(within: .seconds(2)) { gate.pausedCount == 1 }
    #expect(publisher.records.count == 1, "published \(publisher.records.count) times before the first pause ended")
    gate.release()
    try await poll(within: .seconds(2)) { gate.pausedCount == 1 && publisher.records.count == 2 }
    #expect(publisher.records.count == 2, "published \(publisher.records.count) times before the second pause ended")

    gate.fail()
    await running.value
    #expect(publisher.records.count == 2, "published again after the pause was cancelled")
}

@Test(.timeLimit(.minutes(1)))
func gracefulShutdownWithdrawsTheAdvertisement() async throws {
    try await testGracefulShutdown { trigger in
        let publisher = ScriptedPublisher(failures: 0)
        let advertisement = Advertisement(record: record, publisher: publisher, logger: Logger(label: "test"), pause: {})
        let running = Task { await advertisement.run() }
        defer { trigger.triggerGracefulShutdown() }
        try await poll(within: .seconds(2)) { publisher.records.count == 1 }

        trigger.triggerGracefulShutdown()
        await running.value

        #expect(publisher.wasCancelled, "the publication outlived graceful shutdown")
        #expect(publisher.records.count == 1, "published \(publisher.records.count) times, expected once")
    }
}

@Test(arguments: [("tcos-studio-1.local", "tcos-studio-1"), ("tcos-studio-1", "tcos-studio-1"),
                  ("box.example.com", "box.example.com"),
                  (String(repeating: "a", count: 70) + ".local", String(repeating: "a", count: 63)),
                  (String(repeating: "é", count: 40), String(repeating: "é", count: 31))])
func serviceNameIsTheHostWithoutLocalInOneLabel(host: String, name: String) {
    #expect(ServiceRecord(hostName: host, port: 8234).name == name)
}

@Test func avahiPublishesTheNameTypePortAndTXT() {
    #expect(ServiceRecord(name: "studio", port: 8234).avahiPublishArguments
        == ["-s", "studio", "_viam-provisioner._tcp", "8234", "api=v1"])
}

#if canImport(dnssd)
import ProvisionerKit

/// A TCP socket listening on a free port, so ServerBrowser's resolving connection succeeds.
private func listeningSocket() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            bind(descriptor, address, length) == 0 && listen(descriptor, 4) == 0
                && getsockname(descriptor, address, &length) == 0
        }
    }
    guard bound else {
        close(descriptor)
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
}

/// Browses until `done` holds for the servers seen, returning them.
private func browse(until done: ([DiscoveredServer]) -> Bool) async throws -> [DiscoveredServer] {
    var found: [DiscoveredServer] = []
    for try await servers in ServerBrowser().servers() {
        found = servers
        if done(servers) { break }
    }
    return found
}

@Test(.timeLimit(.minutes(1)))
func serverBrowserSeesTheDNSServiceAdvertisementUntilItIsCancelled() async throws {
    let listener = try listeningSocket()
    defer { close(listener.descriptor) }
    let name = "advertisement-test-\(UUID().uuidString.prefix(8))"
    let publication = Task {
        try await DNSServicePublisher(logger: Logger(label: "test"))
            .publish(ServiceRecord(name: name, port: listener.port))
    }

    let found = try await browse { $0.contains { $0.name == name } }
    let server = found.first { $0.name == name }
    #expect(server != nil, "browser saw \(found.map(\.name)), expected \(name)")
    #expect(server?.baseURL.port == listener.port)

    publication.cancel()
    let outcome = await publication.result
    #expect(throws: CancellationError.self) { try outcome.get() }
    let after = try await browse { !$0.contains { $0.name == name } }
    #expect(!after.contains { $0.name == name }, "\(name) still advertised after cancellation")
}
#endif
