import Foundation
@testable import ProvisionerKit
import Testing

/// The fixtures copy the shapes of `cached_cli_config.json`: the user login from a
/// real `viam login`, the API-key login from rdk's `cli/auth.go` (`apiKey`).
private func fixture(_ name: String) throws -> String {
    try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")).path
}

@Test func apiKeyLoginIsReadAsAPIKey() throws {
    let path = try fixture("cli-config-api-key")
    #expect(CLIConfig.login(path: path) == .apiKey(id: "a1b2c3d4-0000-4000-8000-000000000001"))
    let key = try #require(CLIConfig.apiKey(path: path))
    #expect(key.id == "a1b2c3d4-0000-4000-8000-000000000001")
    #expect(key.key == "fixture-key-value")
}

@Test func userLoginIsReadAsUserAndHasNoKey() throws {
    let path = try fixture("cli-config-user")
    #expect(CLIConfig.login(path: path) == .user)
    #expect(CLIConfig.apiKey(path: path) == nil)
}

@Test func missingConfigIsNoLogin() {
    #expect(CLIConfig.login(path: "/nonexistent/cached_cli_config.json") == .none)
}

@Test func defaultsAreReadAndEmptyOnesAreNil() throws {
    let key = CLIConfig.defaults(path: try fixture("cli-config-api-key"))
    #expect(key.org == "org-1")
    #expect(key.location == "loc-1")
    let user = CLIConfig.defaults(path: try fixture("cli-config-user"))
    #expect(user.org == nil)
    #expect(user.location == nil)
}
