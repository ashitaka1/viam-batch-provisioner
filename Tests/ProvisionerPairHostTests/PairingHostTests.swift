import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

/// A sleep the test ends by hand, standing in for the 120-second session timeout.
actor ManualTimer {
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var fired = false

    nonisolated var sleep: @Sendable (Duration) async throws -> Void { { _ in try await self.wait() } }

    private func wait() async throws {
        if fired { return }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func fire() {
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

let payload = PairingPayload(orgID: "o1", orgName: "Acme", keyID: "kid", key: "kval", keyName: "provisioner-app studio 2026-10-31")

/// The app's half of a session, driven directly against the host.
struct AppSide {
    let keys = PairingKeyPair()
    let nonce: PairingNonce

    var hello: PairingHello { PairingHello(nonce: nonce.base64URL, appPublicKey: keys.publicKey.base64EncodedString()) }
    var session: PairingSessionRequest { PairingSessionRequest(nonce: nonce.base64URL, appPublicKey: keys.publicKey.base64EncodedString()) }

    func secrets(_ reply: PairingHelloReply) throws -> PairingSecrets {
        let command = Data(base64Encoded: reply.commandPublicKey)!
        return try PairingSecrets(own: keys, peerPublicKey: command, nonce: nonce, commandPublicKey: command, appPublicKey: keys.publicKey)
    }

    func result(_ outcome: PairingResult.Outcome, _ message: String? = nil) -> PairingResult {
        PairingResult(nonce: nonce.base64URL, appPublicKey: keys.publicKey.base64EncodedString(), outcome: outcome, message: message)
    }
}

func makeHost(timer: ManualTimer = ManualTimer()) -> PairingHost {
    PairingHost(orgID: "o1", orgName: "Acme", sleep: timer.sleep)
}

func collect(_ host: PairingHost) async -> [PairingHost.Event] {
    var events: [PairingHost.Event] = []
    for await event in host.events { events.append(event) }
    return events
}

@Test func helloRepliesWithOrgAndEmitsCode() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let reply = try await host.hello(app.hello)
    #expect(reply.orgID == "o1" && reply.orgName == "Acme")
    var events = host.events.makeAsyncIterator()
    #expect(await events.next() == .connected(code: try app.secrets(reply).code))
}

@Test func firstHelloWinsSecondIsRefused() async throws {
    let host = makeHost()
    _ = try await host.hello(AppSide(nonce: host.nonce).hello)
    await #expect(throws: PairingHostError.alreadyConnected) { try await host.hello(AppSide(nonce: host.nonce).hello) }
}

@Test func wrongNonceRefused() async {
    let host = makeHost()
    await #expect(throws: PairingHostError.wrongNonce) { try await host.hello(AppSide(nonce: .random()).hello) }
}

@Test func otherAppKeyCannotFetch() async throws {
    let host = makeHost()
    _ = try await host.hello(AppSide(nonce: host.nonce).hello)
    await #expect(throws: PairingHostError.unknownSession) { try await host.awaitKey(AppSide(nonce: host.nonce).session) }
}

@Test func keyWaitsForRelease() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let secrets = try app.secrets(try await host.hello(app.hello))
    let fetch = Task { try await host.awaitKey(app.session) }
    // The fetch can't finish before release: release happens only after the waiter is parked.
    await host.waitUntilKeyRequested()
    try await host.release(payload)
    let sealed = try await fetch.value
    #expect(try secrets.open(Data(base64Encoded: sealed.sealed)!) == payload)
}

@Test func keyRequestedAfterReleaseReturnsAtOnce() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let secrets = try app.secrets(try await host.hello(app.hello))
    try await host.release(payload)
    #expect(try secrets.open(Data(base64Encoded: try await host.awaitKey(app.session).sealed)!) == payload)
}

@Test func releaseBeforeConnectionIsRefused() async {
    let host = makeHost()
    await #expect(throws: PairingHostError.unknownSession) { try await host.release(payload) }
}

@Test func cancelBeforeReleaseFailsAwaitKey() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    let fetch = Task { try await host.awaitKey(app.session) }
    await host.waitUntilKeyRequested()
    await host.cancel()
    await #expect(throws: PairingHostError.cancelled) { try await fetch.value }
    await #expect(throws: PairingHostError.cancelled) { try await host.release(payload) }
}

@Test func appCancelEmitsEvent() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    try await host.appCancel(app.session)
    #expect(await collect(host).last == .cancelledByApp)
}

@Test func resultEndsSession() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    try await host.release(payload)
    try await host.report(app.result(.rejected, "bad key"))
    #expect(await collect(host).last == .result(.rejected, message: "bad key"))
}

@Test func timeoutBeforeConnectionEndsSession() async {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    await timer.fire()
    #expect(await collect(host) == [.timedOut])
    await #expect(throws: PairingHostError.timedOut) { try await host.hello(AppSide(nonce: host.nonce).hello) }
}

@Test func timeoutAfterReleaseReportsMintedKey() async throws {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    try await host.release(payload)
    await timer.fire()
    let events = await collect(host)
    #expect(events.last == .timedOut, "events \(events)")
    #expect(await host.released, "the host remembers a key was released, so the command can name it")
}

@Test func resultAfterTimeoutIsRefused() async throws {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    await timer.fire()
    _ = await collect(host)
    await #expect(throws: PairingHostError.timedOut) { try await host.report(app.result(.stored)) }
}
