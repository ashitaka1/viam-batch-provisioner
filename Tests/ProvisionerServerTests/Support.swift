import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import Testing
import ProvisionerAPI
@testable import ProvisionerServer

/// A clock the test advances.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = t0) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

func report(_ kind: Schemas.InstallReport.KindPayload, _ stage: Schemas.InstallStage, name: String? = nil,
            mac: String? = nil, reason: String? = nil) -> Schemas.InstallReport {
    .init(kind: kind, stage: stage, name: name, mac: mac, reason: reason)
}

/// The journal's events after `id`, as (type, stage) pairs for readable comparison.
func eventSummary(_ provisioner: Provisioner, after id: Int = 0) async -> [String] {
    await provisioner.journalEvents(after: id).map(\.summary)
}

extension Schemas.MachineEvent {
    var summary: String {
        switch self {
        case .installProgress(let e): "install-progress \(e.name) \(e.stage.rawValue)"
        case .installFailed(let e): "install-failed \(e.name) \(e.stage.rawValue) \(e.source.rawValue): \(e.reason)"
        case .installComplete(let e): "install-complete \(e.name) \(e.durationSeconds)"
        case .stepReached(let e): "step-reached \(e.name) \(e.step.rawValue)"
        case .downloadProgress(let e): "download-progress \(e.name) \(e.bytes)/\(e.total)"
        case .resync(let e): "resync \(e.latestId)"
        default: "unexpected \(self)"
        }
    }
}

final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Waits until `condition` holds or `limit` passes.
func poll(within limit: Duration, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while await !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The failure `body` throws, or nil when it succeeds.
func failure<T>(_ body: () async throws -> T) async -> ProvisionerFailure? {
    do {
        _ = try await body()
        return nil
    } catch let error as ProvisionerFailure {
        return error
    } catch {
        Issue.record("expected a ProvisionerFailure, got \(error)")
        return nil
    }
}

extension ProvisionerFailure {
    /// The case name alone, for assertions that ignore the message.
    var kind: String {
        switch self {
        case .invalid: "invalid"
        case .invalidName: "invalidName"
        case .notFound: "notFound"
        case .alreadyAssigned: "alreadyAssigned"
        case .queueUnreadable: "queueUnreadable"
        case .internal: "internal"
        }
    }
}

/// Posts an install report to a live server and returns the HTTP status.
@discardableResult
func postReport(port: Int, _ json: String) async throws -> UInt {
    var request = HTTPClientRequest(url: "http://localhost:\(port)/api/v1/install-reports")
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.body = .bytes(ByteBuffer(string: json))
    let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
    _ = try await response.body.collect(upTo: 1 << 16)
    return response.status.code
}

/// A logger whose error messages the test reads back.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var errors: [String] { lock.withLock { lines } }
    fileprivate func append(_ line: String) { lock.withLock { lines.append(line) } }

    var logger: Logger { Logger(label: "captured") { _ in CapturingHandler(log: self) } }
}

private struct CapturingHandler: LogHandler {
    let log: CapturedLog
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        if level >= .error { log.append(message.description) }
    }
}
