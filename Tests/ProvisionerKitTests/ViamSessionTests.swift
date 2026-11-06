import Foundation
@testable import ProvisionerKit
import Testing

/// A `viam` CLI the test scripts by subcommand. `login` can be held open until
/// the task running it is cancelled. All scripted state sits behind one lock:
/// the runner reads it on other threads while the test changes it.
private final class ScriptedCLI: @unchecked Sendable {
    struct Script {
        var loggedIn: Bool
        var token: String
        var account = "avery@example.com"
        var holdLogin = false
        var tokenFails = false
        var whoamiFails = false
        var logoutFails = false
        var missing = false
        var calls: [[String]] = []
    }

    private let lock = NSLock()
    private var script: Script
    let loginStarted = AsyncStream<Void>.makeStream()

    init(loggedIn: Bool = true, token: String = jwt(expiresIn: 3600)) {
        script = Script(loggedIn: loggedIn, token: token)
    }

    func update(_ change: (inout Script) -> Void) { lock.withLock { change(&script) } }
    var calls: [[String]] { lock.withLock { script.calls } }
    var tokenReads: Int { calls.filter { $0 == ["login", "print-access-token"] }.count }
    var logins: Int { calls.filter { $0 == ["login"] }.count }

    var cli: ViamCLI {
        ViamCLI { arguments, onLine in
            let script = self.lock.withLock {
                self.script.calls.append(arguments)
                return self.script
            }
            if script.missing { throw ViamCLIError.notInstalled }
            switch arguments {
            case ["login"]:
                onLine("  https://auth.viam.com/oauth2/device?user_code=ABCDEF")
                self.loginStarted.continuation.yield()
                if script.holdLogin { try await Task.sleep(for: .seconds(3600)) }
                self.update { $0.loggedIn = true }
                return (0, "", "")
            case ["logout"]:
                if script.logoutFails { return (1, "", "Error: couldn't write config\n") }
                self.update { $0.loggedIn = false }
                return (0, "", "")
            default:
                guard script.loggedIn else { return (1, "", "Error: not logged in. Run viam login.\n") }
                if arguments == ["whoami"] {
                    return script.whoamiFails ? (1, "", "Error: network\n") : (0, script.account + "\n", "")
                }
                if script.tokenFails { return (1, script.token, script.token + "\nError: network\n") }
                return (0, script.token + "\n", script.token + "\n")
            }
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// An unsigned JWT whose `exp` is `seconds` after `now`. `padding` lengthens the
/// payload so its base64 needs the URL-safe `-` and `_` characters.
private func jwt(expiresIn seconds: TimeInterval, padding: String = "") -> String {
    let payload = Data(#"{"exp":\#(Int(now.timeIntervalSince1970 + seconds)),"p":"\#(padding)"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

private final class Locator: @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: Bool
    private var _calls = 0
    init(installed: Bool) { _installed = installed }
    var installed: Bool {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }
    func locate() -> URL? {
        lock.withLock {
            _calls += 1
            return _installed ? URL(filePath: "/opt/homebrew/bin/viam") : nil
        }
    }
}

@MainActor
private func session(_ cli: ScriptedCLI, locator: Locator = Locator(installed: true),
                     config: CLIConfigFile = CLIConfigFile(), viam: ScriptedAuth = ScriptedAuth()) -> ViamSession {
    ViamSession(locate: { locator.locate() }, makeCLI: { _ in cli.cli }, configPath: config.path,
                baseURL: URL(string: "https://app.viam.com")!, authenticate: viam.authenticate, now: { now })
}

/// A `cached_cli_config.json` in a temporary directory; it starts absent.
private final class CLIConfigFile: Sendable {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "cli-config-\(UUID().uuidString).json").path

    func holdAPIKey(id: String = "key-id-1", key: String = "key-secret-1") {
        write(#"{"base_url":"https://app.viam.com:443","auth":{"key_id":"\#(id)","key_crypto":"\#(key)"}}"#)
    }

    func holdUserLogin() {
        write(#"{"base_url":"https://app.viam.com:443","auth":{"access_token":"t","refresh_token":"r"}}"#)
    }

    private func write(_ text: String) {
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// An error whose description quotes the request, as a transport error may.
private struct QuotingError: Error, CustomStringConvertible {
    let text: String
    var description: String { "request failed: \(text)" }
}

/// Viam's `AuthService/Authenticate`, scripted.
private final class ScriptedAuth: @unchecked Sendable {
    enum Outcome { case token(String), refused, unreachable, failsQuoting(String) }

    private let lock = NSLock()
    private var outcome = Outcome.token(jwt(expiresIn: 3600))
    private var _calls: [(id: String, key: String)] = []

    var calls: [(id: String, key: String)] { lock.withLock { _calls } }
    func answer(_ outcome: Outcome) { lock.withLock { self.outcome = outcome } }

    var authenticate: APIKeyTokenSource.Authenticate {
        { id, key in
            let outcome = self.lock.withLock {
                self._calls.append((id, key))
                return self.outcome
            }
            switch outcome {
            case .token(let token): return token
            case .refused: throw APIKeyRefused()
            case .unreachable: throw URLError(.notConnectedToInternet)
            case .failsQuoting(let text): throw QuotingError(text: text)
            }
        }
    }
}

// MARK: - Loading

@MainActor @Test func missingCLIIsCLIMissing() async {
    let model = session(ScriptedCLI(), locator: Locator(installed: false))
    await model.load()
    #expect(model.state == .cliMissing)
}

@MainActor @Test func cliInstalledLaterIsFoundOnTheNextLoad() async {
    let locator = Locator(installed: false)
    let model = session(ScriptedCLI(), locator: locator)
    await model.load()
    locator.installed = true
    await model.load()
    #expect(model.state == .signedIn(.user("avery@example.com")))
}

@MainActor @Test func cliRemovedMidSessionIsCLIMissingAndLookedForAgain() async {
    let cli = ScriptedCLI()
    let locator = Locator(installed: true)
    let model = session(cli, locator: locator)
    await model.load()
    cli.update { $0.missing = true }
    await model.load()
    #expect(model.state == .cliMissing)
    cli.update { $0.missing = false }
    await model.load()
    #expect(model.state == .signedIn(.user("avery@example.com")))
    #expect(locator.calls == 2, "the CLI was located \(locator.calls) times; a vanished CLI must be located again")
}

@MainActor @Test func loggedOutCLIIsSignedOut() async {
    let model = session(ScriptedCLI(loggedIn: false))
    await model.load()
    #expect(model.state == .signedOut)
}

@MainActor @Test func loggedInCLIShowsAccount() async {
    let model = session(ScriptedCLI())
    await model.load()
    #expect(model.state == .signedIn(.user("avery@example.com")))
}

@MainActor @Test func whoamiFailureShowsNoAccount() async {
    let cli = ScriptedCLI()
    cli.update { $0.whoamiFails = true }
    let model = session(cli)
    await model.load()
    #expect(model.state == .signedIn(.user(nil)))
}

// MARK: - Signing in and out

@MainActor @Test func signInRunsLoginThenShowsAccount() async {
    let cli = ScriptedCLI(loggedIn: false)
    let model = session(cli)
    await model.load()
    await model.signIn()
    #expect(model.state == .signedIn(.user("avery@example.com")))
    #expect(cli.logins == 1, "ran \(cli.calls)")
}

@MainActor @Test func cancelledSignInReturnsToSignedOutAndCanRetry() async {
    let cli = ScriptedCLI(loggedIn: false)
    cli.update { $0.holdLogin = true }
    let model = session(cli)
    await model.load()
    let signing = Task { await model.signIn() }
    var started = cli.loginStarted.stream.makeAsyncIterator()
    await started.next()
    #expect(await eventually { model.state == .signingIn(code: "ABC-DEF") }, "state \(model.state)")
    model.cancelSignIn()
    await signing.value
    #expect(model.state == .signedOut)

    cli.update { $0.holdLogin = false }
    await model.signIn()
    #expect(model.state == .signedIn(.user("avery@example.com")))
}

@MainActor @Test func signInNeverRunsOverAnExistingLogin() async {
    let cli = ScriptedCLI()
    let model = session(cli)
    await model.load()
    await model.signIn()
    #expect(cli.logins == 0, "ran \(cli.calls)")
}

/// A failed token read says nothing about whether the CLI holds a login.
@MainActor @Test func signInAfterAFailedReadDoesNotLogIn() async {
    let cli = ScriptedCLI()
    cli.update { $0.tokenFails = true }
    let model = session(cli)
    await model.load()
    #expect(model.state == .failed("The viam CLI couldn't give the app its login."))
    await model.signIn()
    #expect(cli.logins == 0, "ran \(cli.calls)")
}

@MainActor @Test func signOutRunsLogoutAndForgetsTheToken() async {
    let cli = ScriptedCLI()
    let model = session(cli)
    await model.load()
    await model.signOut()
    #expect(model.state == .signedOut)
    #expect(cli.calls.contains(["logout"]))
    await #expect(throws: ViamCLIError.notLoggedIn) { try await model.tokens.token(refresh: false) }
}

@MainActor @Test func failedSignOutRereadsTheLogin() async {
    let cli = ScriptedCLI()
    cli.update { $0.logoutFails = true }
    let model = session(cli)
    await model.load()
    await model.signOut()
    #expect(model.state == .signedIn(.user("avery@example.com")))
}

// MARK: - The token

@MainActor @Test func tokenIsCachedUntilItNearsExpiry() async throws {
    let cli = ScriptedCLI(token: jwt(expiresIn: 61))
    let model = session(cli)
    _ = try await model.tokens.token(refresh: false)
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 1, "a token 61 s from expiry was read \(cli.tokenReads) times")

    cli.update { $0.token = jwt(expiresIn: 59) }
    _ = try await model.tokens.token(refresh: true)
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 3, "a token 59 s from expiry was reused")
}

@MainActor @Test func urlSafeBase64PayloadIsDecoded() async throws {
    let token = jwt(expiresIn: 3600, padding: "??>>??>>~~")
    #expect(token.contains("-") || token.contains("_"), "the fixture doesn't exercise base64url")
    let cli = ScriptedCLI(token: token)
    let model = session(cli)
    _ = try await model.tokens.token(refresh: false)
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 1, "a fresh base64url token was read \(cli.tokenReads) times")
}

@MainActor @Test func tokenWithoutAnExpiryIsCachedUntilRefresh() async throws {
    let cli = ScriptedCLI(token: "opaque-token")
    let model = session(cli)
    _ = try await model.tokens.token(refresh: false)
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 1)
    _ = try await model.tokens.token(refresh: true)
    #expect(cli.tokenReads == 2)
}

@MainActor @Test func refreshReturnsTheNewToken() async throws {
    let cli = ScriptedCLI()
    let model = session(cli)
    _ = try await model.tokens.token(refresh: false)
    let newer = jwt(expiresIn: 7200)
    cli.update { $0.token = newer }
    #expect(try await model.tokens.token(refresh: true) == newer)
}

@MainActor @Test func signOutInTerminalSignsTheSessionOut() async {
    let cli = ScriptedCLI()
    let model = session(cli)
    await model.load()
    cli.update { $0.loggedIn = false }
    await #expect(throws: ViamCLIError.notLoggedIn) { try await model.tokens.token(refresh: true) }
    #expect(model.state == .signedOut)
}

/// Viam refusing a token the CLI still hands out: the login is dead even though the CLI holds it.
@MainActor @Test func rejectedTokenSignsTheSessionOut() async {
    let cli = ScriptedCLI()
    let model = session(cli)
    await model.load()
    await model.tokens.rejected()
    #expect(model.state == .signedOut)
    #expect(!cli.calls.contains(["logout"]), "a refused token must not sign the CLI out in Terminal")
}

@MainActor @Test func signInAfterARejectedTokenLogsIn() async {
    let cli = ScriptedCLI()
    let model = session(cli)
    await model.load()
    await model.tokens.rejected()
    await model.signIn()
    #expect(cli.logins == 1)
}

// MARK: - API-key login

@MainActor @Test func apiKeyLoginSignsInAsTheKeyWithTheKeyFromTheConfig() async {
    let cli = ScriptedCLI(loggedIn: false)
    let config = CLIConfigFile()
    config.holdAPIKey(id: "key-id-1", key: "key-secret-1")
    let viam = ScriptedAuth()
    let model = session(cli, config: config, viam: viam)
    await model.load()
    #expect(model.state == .signedIn(.apiKey(id: "key-id-1")))
    #expect(viam.calls.map(\.id) == ["key-id-1"])
    #expect(viam.calls.map(\.key) == ["key-secret-1"])
    #expect(cli.tokenReads == 0, "an API-key login has no CLI token to print")
}

@MainActor @Test func apiKeyTokenIsReusedUntilItNearsExpiry() async throws {
    let config = CLIConfigFile()
    config.holdAPIKey()
    let viam = ScriptedAuth()
    viam.answer(.token(jwt(expiresIn: 61)))
    let model = session(ScriptedCLI(), config: config, viam: viam)
    _ = try await model.tokens.token(refresh: false)
    _ = try await model.tokens.token(refresh: false)
    #expect(viam.calls.count == 1, "a token 61 s from expiry was exchanged \(viam.calls.count) times")

    viam.answer(.token(jwt(expiresIn: 59)))
    _ = try await model.tokens.token(refresh: true)
    _ = try await model.tokens.token(refresh: false)
    #expect(viam.calls.count == 3, "a token 59 s from expiry was reused")
}

@MainActor @Test func refusedKeySignsTheSessionOut() async {
    let config = CLIConfigFile()
    config.holdAPIKey()
    let viam = ScriptedAuth()
    let model = session(ScriptedCLI(), config: config, viam: viam)
    await model.load()
    viam.answer(.refused)
    await #expect(throws: ViamCLIError.notLoggedIn) { try await model.tokens.token(refresh: true) }
    #expect(model.state == .signedOut)
}

@MainActor @Test func rejectedKeyTokenSignsTheSessionOutButNotTheCLI() async {
    let cli = ScriptedCLI()
    let config = CLIConfigFile()
    config.holdAPIKey()
    let model = session(cli, config: config)
    await model.load()
    await model.tokens.rejected()
    #expect(model.state == .signedOut)
    #expect(!cli.calls.contains(["logout"]))
}

@MainActor @Test func failedExchangeFailsWithoutTheKey() async {
    let config = CLIConfigFile()
    config.holdAPIKey(key: "key-secret-1")
    let viam = ScriptedAuth()
    viam.answer(.failsQuoting("key-secret-1"))
    let model = session(ScriptedCLI(), config: config, viam: viam)
    await model.load()
    #expect(model.state == .failed("Viam couldn't be reached to check the API key."))
}

@MainActor @Test func keyRefusedAtLoadIsSignedOut() async {
    let config = CLIConfigFile()
    config.holdAPIKey()
    let viam = ScriptedAuth()
    viam.answer(.refused)
    let model = session(ScriptedCLI(), config: config, viam: viam)
    await model.load()
    #expect(model.state == .signedOut)
}

/// A config naming a key without its secret holds no usable key.
@MainActor @Test func keyWithoutItsSecretSignsTheSessionOut() async {
    let config = CLIConfigFile()
    config.holdAPIKey(key: "")
    let viam = ScriptedAuth()
    let model = session(ScriptedCLI(), config: config, viam: viam)
    await model.load()
    #expect(model.state == .signedOut)
    #expect(viam.calls.isEmpty)
}

@MainActor @Test func signingOutAKeyLoginRunsLogout() async {
    let cli = ScriptedCLI()
    let config = CLIConfigFile()
    config.holdAPIKey()
    let model = session(cli, config: config)
    await model.load()
    await model.signOut()
    #expect(model.state == .signedOut)
    #expect(cli.calls.contains(["logout"]))
}

/// `viam login api-key` in Terminal replaces the user login while the app runs.
@MainActor @Test func tokensFollowTheLoginTheCLIHoldsNow() async throws {
    let cli = ScriptedCLI()
    let config = CLIConfigFile()
    config.holdUserLogin()
    let viam = ScriptedAuth()
    let model = session(cli, config: config, viam: viam)
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 1)
    config.holdAPIKey()
    let token = jwt(expiresIn: 1800)
    viam.answer(.token(token))
    #expect(try await model.tokens.token(refresh: false) == token)
    #expect(viam.calls.count == 1)

    config.holdUserLogin()
    _ = try await model.tokens.token(refresh: false)
    #expect(cli.tokenReads == 1, "the user login's cached token is used again")
    #expect(viam.calls.count == 1, "a user login never exchanges a key")
}

/// The code reaches the session through a hop to the main actor.
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
