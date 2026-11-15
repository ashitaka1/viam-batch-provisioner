import Foundation
import Logging
import ServiceLifecycle

/// The DNS-SD service clients browse for: `ServerBrowser` in ProvisionerKit.
struct ServiceRecord: Sendable, Equatable {
    static let type = "_viam-provisioner._tcp"
    static let txt = [("api", "v1")]

    var name: String
    var port: Int

    init(name: String, port: Int) {
        self.name = name
        self.port = port
    }

    /// Named for the host, without its `.local` domain, cut to the 63 bytes a DNS label holds (RFC 6763 §4.1.1).
    init(hostName: String, port: Int) {
        let suffix = ".local"
        var name = hostName.hasSuffix(suffix) ? String(hostName.dropLast(suffix.count)) : hostName
        while name.utf8.count > 63 { name.removeLast() }
        self.init(name: name, port: port)
    }

    /// The TXT record in DNS wire format: each `key=value` prefixed by its length (RFC 6763 §6).
    static var txtRecord: [UInt8] {
        txt.flatMap { key, value in
            let pair = Array("\(key)=\(value)".utf8)
            return [UInt8(pair.count)] + pair
        }
    }

    /// `avahi-publish`'s arguments for this record.
    var avahiPublishArguments: [String] {
        ["-s", name, Self.type, String(port)] + Self.txt.map { "\($0)=\($1)" }
    }
}

/// Registers a service with the platform's mDNS responder (decision 34).
protocol ServicePublisher: Sendable {
    /// Holds the registration until cancelled. Throws when the registration fails or ends.
    func publish(_ record: ServiceRecord) async throws
}

/// The platform's publisher: DNSServiceRegister on macOS, `avahi-publish` on Linux.
func platformPublisher(logger: Logger) -> any ServicePublisher {
    #if canImport(dnssd)
    DNSServicePublisher(logger: logger)
    #else
    AvahiPublisher()
    #endif
}

/// Advertises the API until graceful shutdown, registering again after each failure.
struct Advertisement: Service {
    let record: ServiceRecord
    let publisher: any ServicePublisher
    let logger: Logger
    /// Waits between a failed registration and the next.
    var pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }

    func run() async {
        await cancelWhenGracefulShutdown {
            logger.info("advertising \(record.name) as \(ServiceRecord.type) on port \(record.port)")
            while !Task.isCancelled {
                do {
                    try await publisher.publish(record)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    logger.error("advertising \(ServiceRecord.type) failed, retrying: \(error)")
                }
                do { try await pause() } catch { return }
            }
        }
    }
}

#if canImport(dnssd)
import dnssd

struct DNSServiceError: Error, CustomStringConvertible {
    let code: DNSServiceErrorType
    var description: String { "DNSServiceRegister error \(code)" }
}

struct DNSServicePublisher: ServicePublisher {
    let logger: Logger

    func publish(_ record: ServiceRecord) async throws {
        let registration = Registration(logger: logger)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registration.start(record, continuation)
            }
        } onCancel: {
            registration.end(CancellationError())
        }
    }
}

/// One DNSServiceRegister call. State is confined to `queue`, where mDNSResponder's replies arrive.
private final class Registration: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProvisionerServer.Advertisement")
    private let logger: Logger
    private var service: DNSServiceRef?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var ended = false

    init(logger: Logger) { self.logger = logger }

    func start(_ record: ServiceRecord, _ continuation: CheckedContinuation<Void, any Error>) {
        queue.async { [self] in
            guard !ended else { return continuation.resume(throwing: CancellationError()) }
            self.continuation = continuation
            let txt = ServiceRecord.txtRecord
            let context = Unmanaged.passUnretained(self).toOpaque()
            let code = DNSServiceRegister(&service, 0, 0, record.name, ServiceRecord.type, nil, nil,
                                          UInt16(record.port).bigEndian, UInt16(txt.count), txt,
                                          registered, context)
            guard code == kDNSServiceErr_NoError else { return finish(DNSServiceError(code: code)) }
            let attached = DNSServiceSetDispatchQueue(service, queue)
            if attached != kDNSServiceErr_NoError { finish(DNSServiceError(code: attached)) }
        }
    }

    func end(_ error: any Error) {
        queue.async { [self] in finish(error) }
    }

    fileprivate func reply(_ code: DNSServiceErrorType, name: String) {
        if code == kDNSServiceErr_NoError {
            logger.info("registered \(name) with mDNSResponder")
        } else {
            finish(DNSServiceError(code: code))
        }
    }

    /// Withdraws the registration and resumes the waiting publisher. Deallocating on `queue`
    /// guarantees no reply arrives after, so `self` outlives every use of the context pointer.
    private func finish(_ error: any Error) {
        ended = true
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private func registered(_ service: DNSServiceRef?, _ flags: DNSServiceFlags, _ code: DNSServiceErrorType,
                        _ name: UnsafePointer<CChar>?, _ type: UnsafePointer<CChar>?,
                        _ domain: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let registration = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
    registration.reply(code, name: name.map { String(cString: $0) } ?? "")
}

#else

struct AvahiPublisherExited: Error, CustomStringConvertible {
    let status: Int32
    var description: String { "avahi-publish exited with status \(status)" }
}

/// Runs `avahi-publish`, which holds the registration with avahi-daemon while it runs.
struct AvahiPublisher: ServicePublisher {
    func publish(_ record: ServiceRecord) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["avahi-publish"] + record.avahiPublishArguments
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        throw AvahiPublisherExited(status: status)
    }
}
#endif
