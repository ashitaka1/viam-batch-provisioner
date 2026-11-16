import Foundation
@testable import ProvisionerServer
import Testing

private let mac1 = "aa:bb:cc:00:00:01"
private let mac2 = "aa:bb:cc:00:00:02"

/// A provisioner serving on port 8234 with `m-1` and `m-2` queued with an environment.
private func queued(root: URL? = nil) async throws -> (Provisioner, DataDirectory) {
    let (provisioner, dir) = try makeImageProvisioner(serverPort: 8234, root: root)
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment()),
                                         request("m-2", environment: validEnvironment())])
    return (provisioner, dir)
}

private func text(_ url: URL) -> String? {
    FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
}

private func installConfig(_ name: String, _ dir: DataDirectory) throws -> String {
    let token = try String(contentsOf: dir.credentials(name).appending(path: "token"), encoding: .utf8)
    return installBootConfig(name: name, token: token, port: 8234, imageFile: testImageName)
}

@Test func startupWritesTheMenu() async throws {
    let (_, dir) = try makeImageProvisioner(serverPort: 8234)
    #expect(text(dir.menu) == menuConfig(port: 8234, bootImagePath: "ubuntu/\(testImageName)"))
}

@Test func withoutAServerPortNoTFTPFileIsWritten() async throws {
    let (provisioner, dir) = try makeImageProvisioner()
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment())])
    _ = try await provisioner.bind("m-1", mac: mac1)
    #expect(!FileManager.default.fileExists(atPath: dir.tftp.path))
}

@Test func bindWritesTheInstallBootConfig() async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: "AA-BB-CC-00-00-01")
    #expect(text(dir.bootConfig(mac1)) == (try installConfig("m-1", dir)))
}

@Test func doneWritesExit() async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))
    #expect(text(dir.bootConfig(mac1)) == exitBootConfig)
}

@Test func failureKeepsTheInstallBootConfig() async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    _ = try await provisioner.report(report(.failed, .installer, name: "m-1"))
    #expect(text(dir.bootConfig(mac1)) == (try installConfig("m-1", dir)))
}

@Test func unbindRemovalAndRebindDeleteTheOldFile() async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    try await provisioner.unbind("m-1")
    #expect(text(dir.bootConfig(mac1)) == nil)

    _ = try await provisioner.bind("m-1", mac: mac1)
    _ = try await provisioner.bind("m-1", mac: mac2)
    #expect(text(dir.bootConfig(mac1)) == nil)
    #expect(text(dir.bootConfig(mac2)) == (try installConfig("m-1", dir)))

    try await provisioner.remove("m-1")
    #expect(text(dir.bootConfig(mac2)) == nil)
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment())])
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.bootConfigs.path))?.isEmpty ?? true)
}

@Test func startupRewritesFromTheQueue() async throws {
    let root = try temporaryDirectory()
    let (provisioner, dir) = try await queued(root: root)
    _ = try await provisioner.bind("m-1", mac: mac1)
    _ = try await provisioner.bind("m-2", mac: mac2)
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))
    try FileManager.default.removeItem(at: dir.bootConfig(mac2))
    let stray = dir.bootConfig("ff:ff:ff:ff:ff:ff")
    try Data("stale".utf8).write(to: stray)

    _ = try makeImageProvisioner(serverPort: 8234, root: root)
    #expect(text(dir.bootConfig(mac1)) == exitBootConfig)
    #expect(text(dir.bootConfig(mac2)) == (try installConfig("m-2", dir)))
    #expect(text(stray) == nil)
}

@Test(.enabled(if: directoryPermissionsApply, "root ignores the read-only boot config directory"))
func failedWriteLeavesTheQueueUnchanged() async throws {
    let (provisioner, dir) = try await queued()
    try FileManager.default.createDirectory(at: dir.bootConfigs, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.bootConfigs.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.bootConfigs.path) }
    #expect(await failure { try await provisioner.bind("m-1", mac: mac1) }?.kind == "internal")
    #expect(try await provisioner.entry("m-1").mac == nil)
}

/// `m-1` bound to `mac1`, then the boot config directory made read-only for the test's body.
private func withReadOnlyBootConfigs(_ body: (Provisioner, DataDirectory) async throws -> Void) async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.bootConfigs.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.bootConfigs.path) }
    try await body(provisioner, dir)
}

@Test(.enabled(if: directoryPermissionsApply, "root ignores the read-only boot config directory"))
func failedDeleteKeepsTheBindingOnUnbind() async throws {
    try await withReadOnlyBootConfigs { provisioner, dir in
        #expect(await failure { try await provisioner.unbind("m-1") }?.kind == "internal")
        let entry = try await provisioner.entry("m-1")
        #expect(entry.mac == mac1)
        let expected = try installConfig("m-1", dir)
        #expect(text(dir.bootConfig(mac1)) == expected)
    }
}

@Test(.enabled(if: directoryPermissionsApply, "root ignores the read-only boot config directory"))
func failedDeleteKeepsTheEntryOnRemove() async throws {
    try await withReadOnlyBootConfigs { provisioner, _ in
        #expect(await failure { try await provisioner.remove("m-1") }?.kind == "internal")
        let entry = try await provisioner.entry("m-1")
        #expect(entry.mac == mac1)
    }
}

@Test(.enabled(if: directoryPermissionsApply, "root ignores the read-only boot config directory"))
func failedRebindKeepsTheOldBinding() async throws {
    try await withReadOnlyBootConfigs { provisioner, dir in
        #expect(await failure { try await provisioner.bind("m-1", mac: mac2) }?.kind == "internal")
        let entry = try await provisioner.entry("m-1")
        #expect(entry.mac == mac1)
        #expect(text(dir.bootConfig(mac2)) == nil)
    }
}

@Test func aPXEOfferBringsTheBootConfigBackInStep() async throws {
    let (provisioner, dir) = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    try FileManager.default.removeItem(at: dir.bootConfig(mac1))
    try Data("stale".utf8).write(to: dir.bootConfig(mac2))

    await provisioner.observe(.offered(mac: mac1))
    await provisioner.observe(.offered(mac: mac2))
    #expect(text(dir.bootConfig(mac1)) == (try installConfig("m-1", dir)))
    #expect(text(dir.bootConfig(mac2)) == nil)
}

@Test func anUnreadableQueueStartsWithEveryMachineBootingFromDisk() async throws {
    let root = try temporaryDirectory()
    let (provisioner, dir) = try await queued(root: root)
    _ = try await provisioner.bind("m-1", mac: mac1)
    try FileManager.default.removeItem(at: dir.menu)
    try Data("not json".utf8).write(to: dir.queue)

    _ = try makeImageProvisioner(serverPort: 8234, root: root)
    #expect(text(dir.menu) == menuConfig(port: 8234, bootImagePath: "ubuntu/\(testImageName)"))
    #expect(text(dir.bootConfig(mac1)) == nil)
}
