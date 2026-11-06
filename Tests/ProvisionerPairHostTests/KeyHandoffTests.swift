import Foundation
import ProvisionerKit
@testable import ProvisionerPairHost
import Testing

private let keyName = "provisioner-app studio 2026-10-31"
private let hint = #"Delete it in Viam: Organization → API keys → "provisioner-app studio 2026-10-31"."#
private let keyOutput = "Key ID: kid\nKey Value: kval\n"

private func cli(stdout: String = keyOutput, before: @escaping @Sendable () async -> Void = {}) -> ViamCLI {
    ViamCLI(run: { _, _ in
        await before()
        return (0, stdout, "")
    })
}

/// A host whose app has connected and is waiting for the key.
private func connectedApp(timer: ManualTimer = ManualTimer()) async throws
    -> (host: PairingHost, app: AppSide, key: Task<PairingSealed, any Error>) {
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    let key = Task { try await host.awaitKey(app.session) }
    await host.waitUntilKeyRequested()
    return (host, app, key)
}

/// Runs the handoff against `host`'s events, as provisioner-pair does after the operator confirms.
private func handOff(_ host: PairingHost, _ cli: ViamCLI) -> Task<PairingEnd, Never> {
    Task {
        var events = host.events.makeAsyncIterator()
        return await KeyHandoff(host: host, cli: cli, orgID: "o1", orgName: "Acme", keyName: keyName)
            .run { await events.next() }
    }
}

@Test(.timeLimit(.minutes(1))) func storedKeySignsIn() async throws {
    let (host, app, key) = try await connectedApp()
    let end = handOff(host, cli())
    _ = try await key.value
    try await host.report(app.result(.stored))
    #expect(await end.value == PairingEnd(message: "Signed in to Acme.", succeeded: true))
}

@Test(.timeLimit(.minutes(1))) func unparsableKeyCancelsAndNamesTheKey() async throws {
    let (host, _, key) = try await connectedApp()
    let end = await handOff(host, cli(stdout: "Created.\n")).value
    #expect(end == PairingEnd(message: "The viam CLI created a key but its output couldn't be read. \(hint)", succeeded: false))
    await #expect(throws: PairingHostError.cancelled, "the app is told the session ended") { try await key.value }
}

@Test(.timeLimit(.minutes(1))) func sessionEndingBeforeReleaseNamesTheKey() async throws {
    let (host, app, _) = try await connectedApp()
    let cancelWhileCreating = cli(before: { try? await host.appCancel(app.session) })
    let end = await handOff(host, cancelWhileCreating).value
    #expect(end == PairingEnd(message: "The pairing ended before the key was sent. \(hint)", succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func timeoutAfterReleaseNamesTheKey() async throws {
    let timer = ManualTimer()
    let (host, _, key) = try await connectedApp(timer: timer)
    let end = handOff(host, cli())
    _ = try await key.value
    await timer.waitForSleeps(2)
    await timer.fire(sleep: 1)
    #expect(await end.value == PairingEnd(message: """
        Timed out waiting for the app after creating key "\(keyName)". If the app's Settings → Organizations \
        doesn't list Acme, delete it in Viam: Organization → API keys → "\(keyName)".
        """, succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func rejectedKeyNamesTheKey() async throws {
    let (host, app, key) = try await connectedApp()
    let end = handOff(host, cli())
    _ = try await key.value
    try await host.report(app.result(.rejected, "key revoked"))
    #expect(await end.value == PairingEnd(message: "The app couldn't use key \"\(keyName)\": key revoked. \(hint)", succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func appCancelAfterReleaseNamesTheKey() async throws {
    let (host, app, key) = try await connectedApp()
    let end = handOff(host, cli())
    _ = try await key.value
    try await host.appCancel(app.session)
    #expect(await end.value == PairingEnd(message: "Cancelled in the app after the key was created. \(hint)", succeeded: false))
}
