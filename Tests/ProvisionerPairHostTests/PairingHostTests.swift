import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

/// Sleeps the test ends by hand, standing in for the session's deadlines.
/// `fire()` ends every sleep, now and later; `fire(sleep:)` ends one.
actor ManualTimer {
    private var sleeps: [(duration: Duration, waiter: CheckedContinuation<Void, any Error>?)] = []
    private var fired: Set<Int> = []
    private var firedAll = false

    nonisolated var sleep: @Sendable (Duration) async throws -> Void { { try await self.wait($0) } }

    /// The durations asked for, in order.
    var requested: [Duration] { sleeps.map(\.duration) }

    private func wait(_ duration: Duration) async throws {
        let index = sleeps.count
        sleeps.append((duration, nil))
        if firedAll || fired.contains(index) { return }
        try await withCheckedThrowingContinuation { sleeps[index].waiter = $0 }
    }

    func fire() {
        firedAll = true
        for index in sleeps.indices { fire(sleep: index) }
    }

    func fire(sleep index: Int) {
        fired.insert(index)
        guard sleeps.indices.contains(index) else { return }
        sleeps[index].waiter?.resume()
        sleeps[index].waiter = nil
    }

    /// Suspends until `count` sleeps have been requested.
    func waitForSleeps(_ count: Int) async {
        while sleeps.count < count { await Task.yield() }
    }
}

let payload = PairingPayload(orgID: "o1", orgName: "Acme", keyID: "kid", key: "kval", keyName: "provisioner-app studio 2026-10-31")

/// The app's half of a session, driven directly against the host.
struct AppSide {
    let keys = PairingKeyPair()
    let appNonce = PairingNonce.random()
    let nonce: PairingNonce

    var hello: PairingHello {
        PairingHello(nonce: nonce.base64URL,
                     commitment: PairingCommitment.make(appPublicKey: keys.publicKey, appNonce: appNonce).base64EncodedString())
    }
    var reveal: PairingReveal {
        PairingReveal(nonce: nonce.base64URL, appPublicKey: keys.publicKey.base64EncodedString(), appNonce: appNonce.base64URL)
    }
    var session: PairingSessionRequest { PairingSessionRequest(nonce: nonce.base64URL, appPublicKey: keys.publicKey.base64EncodedString()) }

    func secrets(_ reply: PairingHelloReply) throws -> PairingSecrets {
        let command = Data(base64Encoded: reply.commandPublicKey)!
        return try PairingSecrets(own: keys, peerPublicKey: command, nonce: nonce, commandPublicKey: command,
                                  appPublicKey: keys.publicKey, appNonce: appNonce)
    }

    /// hello then reveal; returns the app's secrets.
    func connect(_ host: PairingHost) async throws -> PairingSecrets {
        let reply = try await host.hello(hello)
        try await host.reveal(reveal)
        return try secrets(reply)
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

@Test(.timeLimit(.minutes(1))) func helloRepliesWithOrgAndEmitsCode() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let reply = try await host.hello(app.hello)
    #expect(reply.orgID == "o1" && reply.orgName == "Acme")
    try await host.reveal(app.reveal)
    var events = host.events.makeAsyncIterator()
    #expect(await events.next() == .connected(code: try app.secrets(reply).code))
}

@Test(.timeLimit(.minutes(1))) func firstHelloWinsSecondIsRefused() async throws {
    let host = makeHost()
    _ = try await host.hello(AppSide(nonce: host.nonce).hello)
    await #expect(throws: PairingHostError.alreadyConnected) { try await host.hello(AppSide(nonce: host.nonce).hello) }
}

@Test(.timeLimit(.minutes(1))) func wrongNonceRefused() async {
    let host = makeHost()
    await #expect(throws: PairingHostError.wrongNonce) { try await host.hello(AppSide(nonce: .random()).hello) }
}

@Test(.timeLimit(.minutes(1))) func otherAppKeyCannotFetch() async throws {
    let host = makeHost()
    _ = try await AppSide(nonce: host.nonce).connect(host)
    await #expect(throws: PairingHostError.unknownSession) { try await host.awaitKey(AppSide(nonce: host.nonce).session) }
}

@Test(.timeLimit(.minutes(1))) func keyWaitsForRelease() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let secrets = try await app.connect(host)
    let fetch = Task { try await host.awaitKey(app.session) }
    // The fetch can't finish before release: release happens only after the waiter is parked.
    await host.waitUntilKeyRequested()
    try await host.release(payload)
    let sealed = try await fetch.value
    #expect(try secrets.open(Data(base64Encoded: sealed.sealed)!) == payload)
}

@Test(.timeLimit(.minutes(1))) func keyRequestedAfterReleaseReturnsAtOnce() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    let secrets = try await app.connect(host)
    try await host.release(payload)
    #expect(try secrets.open(Data(base64Encoded: try await host.awaitKey(app.session).sealed)!) == payload)
}

@Test(.timeLimit(.minutes(1))) func releaseBeforeConnectionIsRefused() async {
    let host = makeHost()
    await #expect(throws: PairingHostError.unknownSession) { try await host.release(payload) }
}

@Test(.timeLimit(.minutes(1))) func cancelBeforeReleaseFailsAwaitKey() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    let fetch = Task { try await host.awaitKey(app.session) }
    await host.waitUntilKeyRequested()
    await host.cancel()
    await #expect(throws: PairingHostError.cancelled) { try await fetch.value }
    await #expect(throws: PairingHostError.cancelled) { try await host.release(payload) }
}

@Test(.timeLimit(.minutes(1))) func appCancelEmitsEvent() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    try await host.appCancel(app.session)
    #expect(await collect(host).last == .cancelledByApp)
}

@Test(.timeLimit(.minutes(1))) func resultEndsSession() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    try await host.release(payload)
    try await host.report(app.result(.rejected, "bad key"))
    #expect(await collect(host).last == .result(.rejected, message: "bad key"))
}

@Test(.timeLimit(.minutes(1))) func timeoutBeforeConnectionEndsSession() async {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    await timer.fire()
    #expect(await collect(host) == [.timedOut])
    await #expect(throws: PairingHostError.timedOut) { try await host.hello(AppSide(nonce: host.nonce).hello) }
}

@Test(.timeLimit(.minutes(1))) func timeoutAfterReleaseReportsMintedKey() async throws {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    try await host.release(payload)
    await timer.fire()
    let events = await collect(host)
    #expect(events.last == .timedOut, "events \(events)")
    #expect(await host.released, "the host remembers a key was released, so the command can name it")
}

@Test(.timeLimit(.minutes(1))) func resultAfterTimeoutIsRefused() async throws {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    await timer.fire()
    _ = await collect(host)
    await #expect(throws: PairingHostError.timedOut) { try await host.report(app.result(.stored)) }
}

@Test(.timeLimit(.minutes(1))) func revealMustMatchCommitment() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    let substitute = AppSide(nonce: host.nonce)
    await #expect(throws: PairingHostError.commitmentMismatch) { try await host.reveal(substitute.reveal) }
}

@Test(.timeLimit(.minutes(1))) func noCodeBeforeReveal() async throws {
    let host = makeHost()
    let app = AppSide(nonce: host.nonce)
    _ = try await host.hello(app.hello)
    await #expect(throws: PairingHostError.unknownSession) { try await host.release(payload) }
    await #expect(throws: PairingHostError.unknownSession) { try await host.awaitKey(app.session) }
}

@Test(.timeLimit(.minutes(1))) func revealWithoutHelloIsRefused() async {
    let host = makeHost()
    await #expect(throws: PairingHostError.unknownSession) { try await host.reveal(AppSide(nonce: host.nonce).reveal) }
}

@Test(.timeLimit(.minutes(1))) func releaseGivesTheResultItsOwnWindow() async throws {
    let timer = ManualTimer()
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    try await host.release(payload)
    await timer.waitForSleeps(2)
    #expect(await timer.requested == [.seconds(120), .seconds(30)])
    await timer.fire(sleep: 0)   // the original deadline passes while the app validates
    try await host.report(app.result(.stored))
    #expect(await collect(host).last == .result(.stored, message: nil), "the stored result still counts")
}
