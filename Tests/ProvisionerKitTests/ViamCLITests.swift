import Foundation
@testable import ProvisionerKit
import Testing

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// A runner that records its arguments and answers with canned output.
private final class FakeRunner: @unchecked Sendable {
    var calls: [[String]] = []
    let reply: (status: Int32, stdout: String, stderr: String)

    init(status: Int32 = 0, stdout: String = "", stderr: String = "") { reply = (status, stdout, stderr) }

    var cli: ViamCLI {
        ViamCLI { arguments, onLine in
            self.calls.append(arguments)
            self.reply.stdout.split(separator: "\n").forEach { onLine(String($0)) }
            return self.reply
        }
    }
}

@Test func parsesOrganizations() async throws {
    let runner = FakeRunner(stdout: try fixture("orgs-list"))
    let orgs = try await runner.cli.organizations()
    #expect(orgs.map(\.name) == ["Ascension", "Acme (East) Robotics", "asrs"])
    #expect(orgs.map(\.id) == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                               "33333333-3333-4333-8333-333333333333"])
    #expect(runner.calls == [["organizations", "list"]])
}

@Test func parsesOrganizationsWithColor() async throws {
    let colored = try fixture("orgs-list")
        .replacingOccurrences(of: "\tAscension", with: "\t\u{1B}[1mAscension\u{1B}[0m")
        .replacingOccurrences(of: "(id: ", with: "(\u{1B}[2mid:\u{1B}[0m ")
    let orgs = try await FakeRunner(stdout: colored).cli.organizations()
    #expect(orgs.map(\.name) == ["Ascension", "Acme (East) Robotics", "asrs"])
    #expect(orgs.map(\.id) == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                               "33333333-3333-4333-8333-333333333333"])
}

@Test func parsesCreatedKeyWithColor() async throws {
    let colored = try fixture("api-key-create")
        .replacingOccurrences(of: "Key ID:", with: "\u{1B}[1mKey ID:\u{1B}[0m")
        .replacingOccurrences(of: "Key Value:", with: "\u{1B}[1mKey Value:\u{1B}[0m")
    let key = try await FakeRunner(stdout: colored).cli.createKey(orgID: "o1", name: "n")
    #expect(key.id == "REDACTED-ID")
    #expect(key.key == "REDACTED-KEY")
}

@Test(arguments: ["orgs-list-logged-out.stderr", "orgs-list-token-expired.stderr"])
func detectsLoggedOut(fixtureName: String) async throws {
    let runner = FakeRunner(status: 1, stderr: try fixture(fixtureName))
    await #expect(throws: ViamCLIError.notLoggedIn) { try await runner.cli.organizations() }
}

@Test func emptyOrgListIsUnparsable() async {
    await #expect(throws: ViamCLIError.unparsableOrganizations) {
        try await FakeRunner(stdout: "something else entirely\n").cli.organizations()
    }
}

@Test func missingCLIIsNotInstalled() async {
    await #expect(throws: ViamCLIError.notInstalled) { try await FakeRunner(status: 127).cli.organizations() }
}

@Test func parsesCreatedKey() async throws {
    let runner = FakeRunner(stdout: try fixture("api-key-create"))
    let key = try await runner.cli.createKey(orgID: "o1", name: "provisioner-app studio 2026-10-31")
    #expect(key.id == "REDACTED-ID")
    #expect(key.key == "REDACTED-KEY")
    #expect(runner.calls == [["organizations", "api-key", "create", "--org-id", "o1", "--name", "provisioner-app studio 2026-10-31"]])
}

@Test func unparsableKeyOutputHidesStdout() async {
    let runner = FakeRunner(stdout: "Key Value: SECRET123 but no id line\n")
    let error = await #expect(throws: ViamCLIError.unparsableKey) { try await runner.cli.createKey(orgID: "o1", name: "n") }
    #expect(!"\(String(describing: error))".contains("SECRET123"))
}

@Test func failureCarriesStderrOnly() async {
    let runner = FakeRunner(status: 1, stdout: "Key Value: SECRET123\n", stderr: "Error: permission denied\n")
    await #expect(throws: ViamCLIError.failed("Error: permission denied")) {
        try await runner.cli.createKey(orgID: "o1", name: "n")
    }
}

@Test func loginNoticeOnSuccessIsNotAFailure() async throws {
    let runner = FakeRunner(stdout: try fixture("api-key-create"), stderr: "Warning: your token expires soon; run viam login to refresh it\n")
    let key = try await runner.cli.createKey(orgID: "o1", name: "provisioner-app studio 2026-10-31")
    #expect(key.id == "REDACTED-ID")
}

// MARK: - Token and account

@Test func readsAccessTokenFromStdout() async throws {
    // The CLI writes the token to both streams.
    let runner = FakeRunner(stdout: "tok.en.sig\n", stderr: "tok.en.sig\n")
    #expect(try await runner.cli.accessToken() == "tok.en.sig")
    #expect(runner.calls == [["login", "print-access-token"]])
}

@Test func tokenFailureCarriesNoOutput() async {
    let runner = FakeRunner(status: 1, stdout: "secret.tok.en\n", stderr: "secret.tok.en\nboom\n")
    let error = await #expect(throws: ViamCLIError.tokenUnavailable) { try await runner.cli.accessToken() }
    #expect(!String(describing: error).contains("secret"), "the error described as \(String(describing: error))")
}

@Test func loggedOutTokenIsNotLoggedIn() async throws {
    let runner = FakeRunner(status: 1, stderr: try fixture("orgs-list-logged-out.stderr"))
    await #expect(throws: ViamCLIError.notLoggedIn) { try await runner.cli.accessToken() }
}

@Test func emptyTokenIsNotLoggedIn() async {
    await #expect(throws: ViamCLIError.notLoggedIn) { try await FakeRunner(stdout: "\n").cli.accessToken() }
}

@Test func whoamiReadsTheLastLine() async throws {
    let runner = FakeRunner(stdout: "Warning: CLI Update Check: Your CLI is out of date.\navery@example.com\n")
    #expect(try await runner.cli.whoami() == "avery@example.com")
    #expect(runner.calls == [["whoami"]])
}

@Test func loginAndLogoutRunTheirCommands() async throws {
    let runner = FakeRunner()
    try await runner.cli.login()
    try await runner.cli.logout()
    #expect(runner.calls == [["login"], ["logout"]])
}

@Test func baseURLFromConfig() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "cli-config-\(UUID().uuidString).json")
    try Data(#"{"base_url":"https://app.viam.com:443","auth":{"access_token":"x"}}"#.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(CLIConfig.baseURL(path: file.path)?.absoluteString == "https://app.viam.com:443")
    #expect(CLIConfig.baseURL(path: file.path + ".missing") == nil)
}

// MARK: - Locating the binary

@Test func locatePrefersHomebrew() async {
    let present: Set = ["/opt/homebrew/bin/viam", "/usr/local/bin/viam"]
    let found = await ViamCLI.locate(fileExists: { present.contains($0) }, home: "/Users/x", shellLookup: { nil })
    #expect(found?.path == "/opt/homebrew/bin/viam")
}

@Test func locateFallsBackToLoginShell() async {
    let found = await ViamCLI.locate(
        fileExists: { $0 == "/Users/x/go/bin/viam" }, home: "/Users/x", shellLookup: { "/Users/x/go/bin/viam\n" })
    #expect(found?.path == "/Users/x/go/bin/viam")
}

@Test func locateIgnoresAShellAnswerThatIsntExecutable() async {
    let found = await ViamCLI.locate(fileExists: { _ in false }, home: "/Users/x", shellLookup: { "viam not found\n" })
    #expect(found == nil)
}

@Test func locateReturnsNilWhenNowhere() async {
    let found = await ViamCLI.locate(fileExists: { _ in false }, home: "/Users/x", shellLookup: { nil })
    #expect(found == nil)
}

@Test func runnerCapturesStatusAndBothStreams() async throws {
    let run = ViamCLI.processRunner(executable: URL(filePath: "/bin/sh"))
    let result = try await run(["-c", "echo out; echo err >&2; exit 3"], { _ in })
    #expect(result.status == 3)
    #expect(result.stdout == "out\n")
    #expect(result.stderr == "err\n")
}

@Test func runnerForAVanishedBinaryIsNotInstalled() async {
    let run = ViamCLI.processRunner(executable: URL(filePath: "/nonexistent/viam-\(UUID().uuidString)"))
    await #expect(throws: ViamCLIError.notInstalled) { _ = try await run(["whoami"], { _ in }) }
}

/// A real child process: there is no clock seam between the runner and `Process`.
@Test func cancellingTerminatesTheChild() async throws {
    let run = ViamCLI.processRunner(executable: URL(filePath: "/bin/sleep"))
    let started = ContinuousClock.now
    let task = Task { try await run(["30"], { _ in }) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = try? await task.value
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(5), "the child was still running \(elapsed) after cancellation")
}

/// The crash this guards against: a cancelled wait returned before the child
/// exited, and asking a running `Process` for its status raises.
@Test func cancellingWaitsForAChildThatOutlivesTerminate() async throws {
    let run = ViamCLI.processRunner(executable: URL(filePath: "/bin/sh"))
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        try await run(["-c", "trap '' TERM; echo ready; exec 1>&- 2>&-; sleep 1"], { _ in started.continuation.yield() })
    }
    var ready = started.stream.makeAsyncIterator()
    await ready.next()
    task.cancel()
    let result = try await task.value
    #expect(result.status == 0)
}

@Test func runnerDeliversStdoutLinesBeforeTheChildExits() async throws {
    let run = ViamCLI.processRunner(executable: URL(filePath: "/bin/sh"))
    let lines = AsyncStream<String>.makeStream()
    let task = Task { try await run(["-c", "echo first; exec sleep 30"], { lines.continuation.yield($0) }) }
    var received = lines.stream.makeAsyncIterator()
    #expect(await received.next() == "first")
    task.cancel()
    _ = try? await task.value
}

@Test func loginReportsTheDeviceCodeAsTheBrowserShowsIt() async throws {
    let runner = FakeRunner(stdout: try fixture("login"))
    let codes = Locked<[String]>([])
    try await runner.cli.login { code in codes.withLock { $0.append(code) } }
    #expect(codes.withLock { $0 } == ["MYL-9Y4"])
    #expect(runner.calls == [["login"]])
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
