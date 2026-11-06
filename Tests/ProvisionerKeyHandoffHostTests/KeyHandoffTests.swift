import Foundation
import ProvisionerKit
@testable import ProvisionerKeyHandoffHost
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
    -> (host: HandoffHost, app: AppSide, key: Task<HandoffSealed, any Error>) {
    let host = makeHost(timer: timer)
    let app = AppSide(nonce: host.nonce)
    _ = try await app.connect(host)
    let key = Task { try await host.awaitKey(app.session) }
    await host.waitUntilKeyRequested()
    return (host, app, key)
}

/// Runs the handoff against `host`'s events, as provisioner-handoff does after the operator confirms.
private func handOff(_ host: HandoffHost, _ cli: ViamCLI) -> Task<HandoffEnd, Never> {
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
    #expect(await end.value == HandoffEnd(message: "Signed in to Acme.", succeeded: true))
}

@Test(.timeLimit(.minutes(1))) func cliFailureCancelsWithoutAKey() async throws {
    let (host, _, key) = try await connectedApp()
    let loggedOut = ViamCLI(run: { _, _ in (1, "", "Error: not logged in") })
    let end = await handOff(host, loggedOut).value
    #expect(end == HandoffEnd(message: "Run 'viam login' first.", succeeded: false))
    await #expect(throws: HandoffHostError.cancelled, "the app is told the session ended") { try await key.value }
}

@Test(arguments: [
    (ViamCLIError.notInstalled, "Install the viam CLI: https://docs.viam.com/cli/"),
    (.notLoggedIn, "Run 'viam login' first."),
    (.failed("Error: boom"), "The viam CLI failed: Error: boom"),
    (.unparsableOrganizations, "Couldn't read the viam CLI's organization list. Update it with 'viam update'."),
])
func cliMessages(error: ViamCLIError, expected: String) {
    #expect(handoffCLIMessage(error) == expected)
}

@Test(.timeLimit(.minutes(1))) func eventsEndingAfterReleaseIsATimeout() async throws {
    let (host, _, key) = try await connectedApp()
    let end = Task { await KeyHandoff(host: host, cli: cli(), orgID: "o1", orgName: "Acme", keyName: keyName).run { nil } }
    _ = try await key.value
    #expect(await end.value.message.hasPrefix("Timed out waiting for the app after creating key"))
}

@Test(.timeLimit(.minutes(1))) func connectedEventIsSkipped() async throws {
    let (host, _, key) = try await connectedApp()
    let events = Feed([.connected(code: "1234"), .result(.stored, message: nil)])
    let end = Task { await KeyHandoff(host: host, cli: cli(), orgID: "o1", orgName: "Acme", keyName: keyName).run { await events.next() } }
    _ = try await key.value
    #expect(await end.value == HandoffEnd(message: "Signed in to Acme.", succeeded: true))
}

/// Hands out scripted events, then nil.
private actor Feed {
    private var events: [HandoffHost.Event]
    init(_ events: [HandoffHost.Event]) { self.events = events }
    func next() -> HandoffHost.Event? { events.isEmpty ? nil : events.removeFirst() }
}

@Test(.timeLimit(.minutes(1))) func unparsableKeyCancelsAndNamesTheKey() async throws {
    let (host, _, key) = try await connectedApp()
    let end = await handOff(host, cli(stdout: "Created.\n")).value
    #expect(end == HandoffEnd(message: "The viam CLI created a key but its output couldn't be read. \(hint)", succeeded: false))
    await #expect(throws: HandoffHostError.cancelled, "the app is told the session ended") { try await key.value }
}

@Test(.timeLimit(.minutes(1))) func sessionEndingBeforeReleaseNamesTheKey() async throws {
    let (host, app, _) = try await connectedApp()
    let cancelWhileCreating = cli(before: { try? await host.appCancel(app.session) })
    let end = await handOff(host, cancelWhileCreating).value
    #expect(end == HandoffEnd(message: "The handoff ended before the key was sent. \(hint)", succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func timeoutAfterReleaseNamesTheKey() async throws {
    let timer = ManualTimer()
    let (host, _, key) = try await connectedApp(timer: timer)
    let end = handOff(host, cli())
    _ = try await key.value
    await timer.waitForSleeps(2)
    await timer.fire(sleep: 1)
    #expect(await end.value == HandoffEnd(message: """
        Timed out waiting for the app after creating key "\(keyName)". If the app's Settings → Organizations \
        doesn't list Acme, delete it in Viam: Organization → API keys → "\(keyName)".
        """, succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func rejectedKeyNamesTheKey() async throws {
    let (host, app, key) = try await connectedApp()
    let end = handOff(host, cli())
    _ = try await key.value
    try await host.report(app.result(.rejected, "key revoked"))
    #expect(await end.value == HandoffEnd(message: "The app couldn't use key \"\(keyName)\": key revoked. \(hint)", succeeded: false))
}

@Test(.timeLimit(.minutes(1))) func appCancelAfterReleaseNamesTheKey() async throws {
    let (host, app, key) = try await connectedApp()
    let end = handOff(host, cli())
    _ = try await key.value
    try await host.appCancel(app.session)
    #expect(await end.value == HandoffEnd(message: "Cancelled in the app after the key was created. \(hint)", succeeded: false))
}
