import Foundation
@testable import ProvisionerServer
import Testing

/// `m-1` queued with `validEnvironment()`, its token, and the data directory.
private func seededMachine(credentials: Schemas.ViamCredentials? = nil,
                           bindings: any MachineBindings = NoBindings()) async throws -> (Provisioner, String, DataDirectory) {
    let (provisioner, dir) = try makeProvisioner(bindings: bindings)
    _ = try await provisioner.provision([request("m-1", credentials: credentials, environment: validEnvironment())])
    let path = try #require(await provisioner.seedPath(for: "m-1"))
    return (provisioner, String(path.split(separator: "/").last!), dir)
}

@Test func secretsAreServedOncePerAttempt() async throws {
    let (provisioner, token, _) = try await seededMachine(credentials: creds("a"))
    for file in ["user-data", "viam.json", "tailscale.key"] {
        #expect(try await provisioner.seedFile(file, name: "m-1", token: token, host: "10.1.0.5:8234").count > 0)
        #expect(await seedFailure { try await provisioner.seedFile(file, name: "m-1", token: token, host: "10.1.0.5:8234") } == .notFound)
    }
    #expect(try await provisioner.seedFile("meta-data", name: "m-1", token: token, host: nil) == Data())
    #expect(try await provisioner.seedFile("vendor-data", name: "m-1", token: token, host: nil) == Data())
}

@Test func servedFilesHoldTheStagedSecrets() async throws {
    let (provisioner, token, _) = try await seededMachine(credentials: creds("a"))
    let viam = try await provisioner.seedFile("viam.json", name: "m-1", token: token, host: nil)
    #expect(try JSONDecoder().decode(Schemas.ViamCredentials.self, from: viam) == creds("a"))
    #expect(try await provisioner.seedFile("tailscale.key", name: "m-1", token: token, host: nil) == Data("tskey-auth-x".utf8))
}

@Test func unstagedSecretIsNotFoundAndNotSpent() async throws {
    let (provisioner, token, _) = try await seededMachine()
    #expect(await seedFailure { try await provisioner.seedFile("viam.json", name: "m-1", token: token, host: nil) } == .notFound)
    #expect(await provisioner.machineRecord("m-1")?.secretsServed["viam.json"] == nil)
}

@Test func wrongTokenUnknownFileAndOtherCaseName() async throws {
    let (provisioner, token, _) = try await seededMachine()
    let wrong = String(repeating: "0", count: 32)
    #expect(await seedFailure { try await provisioner.seedFile("user-data", name: "m-1", token: wrong, host: "h:1") } == .notFound)
    #expect(await seedFailure { try await provisioner.seedFile("user-data", name: "m-1", token: "", host: "h:1") } == .notFound)
    #expect(await seedFailure { try await provisioner.seedFile("environment.json", name: "m-1", token: token, host: "h:1") } == .notFound)
    #expect(await seedFailure { try await provisioner.seedFile("user-data", name: "m-2", token: token, host: "h:1") } == .notFound)
    #expect(try await provisioner.seedFile("user-data", name: "M-1", token: token, host: "h:1").count > 0)
}

@Test func renderedUserDataCarriesTheHostAndMachineURL() async throws {
    let (provisioner, token, _) = try await seededMachine()
    let data = try await provisioner.seedFile("user-data", name: "m-1", token: token, host: "10.1.0.5:8234")
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("http://10.1.0.5:8234/scripts/install-report.sh"))
    #expect(text.contains(#"CRED_URL="http://10.1.0.5:8234/machines/by-name/m-1/\#(token)""#))
}

@Test func badHostServesNothingAndSpendsNothing() async throws {
    let (provisioner, token, _) = try await seededMachine()
    for host in [nil, "h\"x", "$(reboot)", "a b", "h\n1", ""] {
        #expect(await seedFailure { try await provisioner.seedFile("user-data", name: "m-1", token: token, host: host) } == .badHost,
                "\(String(describing: host))")
    }
    #expect(try await provisioner.seedFile("user-data", name: "m-1", token: token, host: "h:1").count > 0)
}

@Test func firstUserDataFetchReachesInstalling() async throws {
    let (provisioner, token, _) = try await seededMachine()
    _ = try await provisioner.seedFile("user-data", name: "m-1", token: token, host: "h:1")
    #expect(try await provisioner.entry("m-1").steps?.map(\.step) == [.installing])
    #expect(await eventSummary(provisioner).last == "step-reached m-1 installing")
}

private let secretFiles = ["user-data", "viam.json", "tailscale.key"]

@Test func installReportsNeverReArm() async throws {
    let (provisioner, token, _) = try await seededMachine(credentials: creds("a"))
    for file in secretFiles { _ = try await provisioner.seedFile(file, name: "m-1", token: token, host: "h:1") }
    _ = try await provisioner.report(report(.failed, .installer, name: "m-1"))
    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    for file in secretFiles {
        #expect(await seedFailure { try await provisioner.seedFile(file, name: "m-1", token: token, host: "h:1") } == .notFound,
                "\(file)")
    }
}

@Test func pxeOfferReArms() async throws {
    let (provisioner, token, _) = try await seededMachine(credentials: creds("a"), bindings: FixedBindings())
    for file in secretFiles { _ = try await provisioner.seedFile(file, name: "m-1", token: token, host: "h:1") }
    await provisioner.observe(.offered(mac: "aa:bb:cc:00:00:01"))
    for file in secretFiles {
        #expect(try await provisioner.seedFile(file, name: "m-1", token: token, host: "h:1").count > 0, "\(file)")
    }
}

@Test func requeuedMachinesOldTokenIsRefused() async throws {
    let (provisioner, token, _) = try await seededMachine()
    try await provisioner.remove("m-1")
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment())])
    #expect(await seedFailure { try await provisioner.seedFile("meta-data", name: "m-1", token: token, host: nil) } == .notFound)
}

@Test func nothingIsServedAfterDone() async throws {
    let (provisioner, token, _) = try await seededMachine()
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))
    #expect(await seedFailure { try await provisioner.seedFile("meta-data", name: "m-1", token: token, host: nil) } == .notFound)
}

@Test(.enabled(if: directoryPermissionsApply, "root ignores the read-only machines directory"))
func unsavedServedTimeServesNothing() async throws {
    let (provisioner, token, dir) = try await seededMachine(credentials: creds("a"))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.machines.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.machines.path) }
    #expect(await seedFailure { try await provisioner.seedFile("viam.json", name: "m-1", token: token, host: nil) } == .unsaved)
}

@Test func concurrentUserDataFetchesServeOnce() async throws {
    let (provisioner, token, _) = try await seededMachine()
    let served = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<2 {
            group.addTask { (try? await provisioner.seedFile("user-data", name: "m-1", token: token, host: "h:1")) != nil }
        }
        return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    #expect(served == 1)
}
