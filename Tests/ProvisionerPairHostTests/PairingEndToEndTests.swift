import Darwin
import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

private func withServer(_ body: (PairingHost, PairingHTTPServer) async throws -> Void) async throws {
    let host = makeHost()
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

@Test func pairsOverLoopback() async throws {
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

@Test func secondClientIsRefused() async throws {
    try await withServer { host, server in
        _ = try await PairingClient(link: link(host, server)).hello()
        await #expect(throws: PairingClientError.alreadyPaired) { try await PairingClient(link: link(host, server)).hello() }
    }
}

@Test func commandCancelReachesWaitingApp() async throws {
    try await withServer { host, server in
        let client = PairingClient(link: link(host, server))
        _ = try await client.hello()
        let fetch = Task { try await client.awaitPayload() }
        await host.waitUntilKeyRequested()
        await host.cancel()
        await #expect(throws: PairingClientError.cancelled) { try await fetch.value }
    }
}

@Test func appCancelReachesCommand() async throws {
    try await withServer { host, server in
        let client = PairingClient(link: link(host, server))
        _ = try await client.hello()
        await client.cancel()
        #expect(await collect(host).last == .cancelledByApp)
    }
}

@Test func unknownPathIs404() async throws {
    try await withServer { host, server in
        var request = URLRequest(url: link(host, server).baseURL.appending(path: "nope"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
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

@Test(.enabled(if: externalIPv4() != nil, "no non-loopback IPv4 address"))
func listenerBindsLoopbackOnly() async throws {
    try await withServer { host, server in
        let external = PairingLink(host: externalIPv4()!, port: server.port, nonce: host.nonce)
        await #expect(throws: PairingClientError.self) { try await PairingClient(link: external).hello() }
    }
}
