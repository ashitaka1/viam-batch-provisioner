import Darwin
import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

private func withServer(timer: ManualTimer = ManualTimer(),
                        _ body: (PairingHost, PairingHTTPServer) async throws -> Void) async throws {
    let host = makeHost(timer: timer)
    let server = try await PairingHTTPServer.start(host: host)
    do {
        try await body(host, server)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

private func link(_ host: PairingHost, _ server: PairingHTTPServer) -> PairingLink {
    PairingLink(host: "127.0.0.1", port: server.port, nonce: host.nonce)
}

@Test(.timeLimit(.minutes(1))) func pairsOverLoopback() async throws {
    try await withServer { host, server in
        let client = PairingClient(link: link(host, server))
        var events = host.events.makeAsyncIterator()

        let hello = try await client.hello()
        #expect(hello.orgName == "Acme" && hello.orgID == "o1")
        #expect(await events.next() == .connected(code: hello.code), "both sides show the same code")

        let fetch = Task { try await client.awaitPayload() }
        await host.waitUntilKeyRequested()
        try await host.release(payload)
        #expect(try await fetch.value == payload)

        try await client.report(.stored, message: nil)
        #expect(await events.next() == .result(.stored, message: nil))
    }
}

@Test(.timeLimit(.minutes(1))) func secondClientIsRefused() async throws {
    try await withServer { host, server in
        _ = try await PairingClient(link: link(host, server)).hello()
        await #expect(throws: PairingClientError.alreadyPaired) { try await PairingClient(link: link(host, server)).hello() }
    }
}

@Test(.timeLimit(.minutes(1))) func commandCancelReachesWaitingApp() async throws {
    try await withServer { host, server in
        let client = PairingClient(link: link(host, server))
        _ = try await client.hello()
        let fetch = Task { try await client.awaitPayload() }
        await host.waitUntilKeyRequested()
        await host.cancel()
        await #expect(throws: PairingClientError.cancelled) { try await fetch.value }
    }
}

@Test(.timeLimit(.minutes(1))) func appCancelReachesCommand() async throws {
    try await withServer { host, server in
        let client = PairingClient(link: link(host, server))
        _ = try await client.hello()
        await client.cancel()
        #expect(await collect(host).last == .cancelledByApp)
    }
}

@Test(.timeLimit(.minutes(1))) func unknownPathIs404() async throws {
    try await withServer { host, server in
        var request = URLRequest(url: link(host, server).baseURL.appending(path: "nope"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 404, "status \(String(describing: status))")
    }
}

/// The first non-loopback IPv4 address on an up interface, if any.
private func externalIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return nil
}

@Test(.timeLimit(.minutes(1)), .enabled(if: externalIPv4() != nil, "no non-loopback IPv4 address"))
func listenerBindsLoopbackOnly() async throws {
    try await withServer { host, server in
        let external = PairingLink(host: externalIPv4()!, port: server.port, nonce: host.nonce)
        do {
            _ = try await PairingClient(link: external).hello()
            Issue.record("connected to the listener through \(external.host)")
        } catch PairingClientError.transport {
        } catch {
            Issue.record("expected a transport error, got \(error)")
        }
    }
}

/// POSTs a raw body and returns the status code.
private func post(_ link: PairingLink, _ path: String, _ body: Data) async throws -> Int? {
    var request = URLRequest(url: link.baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.httpBody = body
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode
}

@Test(.timeLimit(.minutes(1))) func timedOutSessionReachesAppAsTimeout() async throws {
    let timer = ManualTimer()
    try await withServer(timer: timer) { host, server in
        await timer.fire()
        _ = await collect(host)
        await #expect(throws: PairingClientError.timedOut) { try await PairingClient(link: link(host, server)).hello() }
    }
}

@Test(.timeLimit(.minutes(1))) func wrongNonceReachesAppAsInvalidSession() async throws {
    try await withServer { host, server in
        let stale = PairingLink(host: "127.0.0.1", port: server.port, nonce: .random())
        await #expect(throws: PairingClientError.invalidSession) { try await PairingClient(link: stale).hello() }
    }
}

@Test(.timeLimit(.minutes(1))) func keyRequestFromAnotherAppIs403() async throws {
    try await withServer { host, server in
        _ = try await PairingClient(link: link(host, server)).hello()
        let other = AppSide(nonce: host.nonce).session
        let status = try await post(link(host, server), "pair/key", JSONEncoder().encode(other))
        #expect(status == 403, "status \(String(describing: status))")
    }
}

@Test(.timeLimit(.minutes(1))) func garbageBodyIs400() async throws {
    try await withServer { host, server in
        let status = try await post(link(host, server), "pair/hello", Data("not json".utf8))
        #expect(status == 400, "status \(String(describing: status))")
    }
}
