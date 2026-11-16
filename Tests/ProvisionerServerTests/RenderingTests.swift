import Foundation
@testable import ProvisionerServer
import Testing

private let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The names in `scripts/build-config.sh`'s envsubst list.
private func buildConfigWhitelist() throws -> [String] {
    let script = try String(contentsOf: repo.appending(path: "scripts/build-config.sh"), encoding: .utf8)
    let list = try #require(script.firstMatch(of: /envsubst '([^']*)'/)).1
    return list.matches(of: /\$\{(\w+)\}/).map { String($0.1) }
}

private func runShell(_ script: String) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", script]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Test func envsubstReplacesOnlyListedNamesOnce() {
    let out = envsubst("a=${A} b=$A c=$AB d=${B} e=$HOME f=${A", ["A": "$B${B}", "B": "x"])
    #expect(out == "a=$B${B} b=$B${B} c=$AB d=x e=$HOME f=${A")
}

@Test func embeddedTemplateIsTheRepositoryTemplate() throws {
    #expect(userDataTemplate == (try String(contentsOf: repo.appending(path: "templates/user-data.tpl"), encoding: .utf8)))
}

@Test func renderedUserDataSubstitutesEveryWhitelistedVariable() throws {
    let rendered = renderUserData(validEnvironment(), server: "10.1.0.5:8234",
                                  machineURL: "http://10.1.0.5:8234/machines/by-name/m-1/t")
    for name in try buildConfigWhitelist() + ["MACHINE_URL"] {
        #expect(!rendered.contains("${\(name)}"), "\(name) left unsubstituted")
    }
    #expect(rendered.contains(#"password: "$6$salt$hash""#))
    #expect(rendered.contains(#"CRED_URL="http://10.1.0.5:8234/machines/by-name/m-1/t""#))
    #expect(rendered.contains("  packages:\n    - curl\n"))
    #expect(!rendered.contains("tskey-auth-x"))
}

@Test func wifiPasswordSurvivesTheNetplanHeredoc() throws {
    let password = #"p"a\s$s`w${TIMEZONE}d $USERNAME"#
    var environment = validEnvironment()
    environment.wifi = .init(ssid: "lab", password: password)
    let rendered = renderUserData(environment, server: "h:1", machineURL: "")
    let line = try #require(rendered.split(separator: "\n").first { $0.contains(#"password: ""#) && !$0.contains("$6$") })
    let shellOutput = try runShell("cat <<NETPLAN\n\(line)\nNETPLAN\n")
    #expect(shellOutput.trimmingCharacters(in: .whitespacesAndNewlines) == #"password: "\#(yamlQuoted(password))""#)
}

@Test func yamlQuotedEscapesBackslashAndQuote() {
    #expect(yamlQuoted(#"a\b"c"#) == #"a\\b\"c"#)
}

@Test func emptyPackagesRenderAnEmptyList() {
    var environment = validEnvironment()
    environment.packages = nil
    #expect(renderUserData(environment, server: "h:1", machineURL: "").contains("  packages:\n    []\n"))
}
