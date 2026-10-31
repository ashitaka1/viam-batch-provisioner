import Foundation
@testable import ProvisionerPairHost
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
        ViamCLI { arguments in
            self.calls.append(arguments)
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
    let colored = try fixture("orgs-list").replacingOccurrences(of: "Organizations", with: "\u{1B}[1mOrganizations\u{1B}[0m")
    let orgs = try await FakeRunner(stdout: colored).cli.organizations()
    #expect(orgs.count == 3)
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
    let key = try await FakeRunner(stdout: try fixture("api-key-create")).cli.createKey(orgID: "o1", name: "provisioner-app studio 2026-10-31")
    #expect(key.id == "REDACTED-ID")
    #expect(key.key == "REDACTED-KEY")
}

@Test func passesNoSecretOnCommandLine() async throws {
    let runner = FakeRunner(stdout: try fixture("api-key-create"))
    _ = try await runner.cli.createKey(orgID: "o1", name: "provisioner-app studio 2026-10-31")
    #expect(runner.calls == [["organizations", "api-key", "create", "--org-id", "o1", "--name", "provisioner-app studio 2026-10-31"]])
}

@Test func unparsableKeyOutputHidesStdout() async {
    let runner = FakeRunner(stdout: "Key Value: SECRET123 but no id line\n")
    do {
        _ = try await runner.cli.createKey(orgID: "o1", name: "n")
        Issue.record("expected unparsableKey")
    } catch {
        #expect(error as? ViamCLIError == .unparsableKey)
        #expect(!String(describing: error).contains("SECRET123"), "error text: \(error)")
    }
}

@Test func failureCarriesStderrOnly() async {
    let runner = FakeRunner(status: 1, stdout: "Key Value: SECRET123\n", stderr: "Error: permission denied\n")
    await #expect(throws: ViamCLIError.failed("Error: permission denied")) {
        try await runner.cli.createKey(orgID: "o1", name: "n")
    }
}
