import Foundation
import ProvisionerNetbootCore
import ProvisionerNetbootXPC
import Testing

@Suite struct TFTPRootFilesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var files: TFTPRootFiles { TFTPRootFiles(root: root) }

    @Test func writesNestedPathCreatingDirectories() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("menu".utf8), to: "grub/macs/aa-bb.cfg")
        #expect(try Data(contentsOf: root.appendingPathComponent("grub/macs/aa-bb.cfg")) == Data("menu".utf8))

        try files.write(Data("new".utf8), to: "grub/macs/aa-bb.cfg")
        #expect(try Data(contentsOf: root.appendingPathComponent("grub/macs/aa-bb.cfg")) == Data("new".utf8))
    }

    @Test(arguments: ["", "/etc/passwd", "../escape", "grub/../../escape", "grub//x", "./x", "grub/"])
    func refusesPathsThatCouldLeaveTheRoot(path: String) {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: NetbootError.invalidPath(path)) { try files.write(Data(), to: path) }
        #expect(throws: NetbootError.invalidPath(path)) { try files.remove(path) }
    }

    @Test func removesFileAndIgnoresMissing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("x".utf8), to: "a.cfg")
        try files.remove("a.cfg")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.cfg").path))
        try files.remove("a.cfg")
    }

    @Test func writeOverDirectoryFailsAndKeepsItsFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("x".utf8), to: "grub/a.cfg")
        #expect { try files.write(Data(), to: "grub") } throws: { error in
            if case NetbootError.writeFailed = error { true } else { false }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("grub/a.cfg")) == Data("x".utf8))
    }

    @Test func refusesToRemoveADirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("x".utf8), to: "grub/a.cfg")
        #expect { try files.remove("grub") } throws: { error in
            if case NetbootError.writeFailed = error { true } else { false }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("grub/a.cfg")) == Data("x".utf8))
    }

    @Test func refusesPathsThroughASymlinkOutOfTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("victim"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        #expect(throws: NetbootError.invalidPath("link/victim")) { try files.write(Data("x".utf8), to: "link/victim") }
        #expect(throws: NetbootError.invalidPath("link/new/file")) { try files.write(Data("x".utf8), to: "link/new/file") }
        #expect(throws: NetbootError.invalidPath("link/victim")) { try files.remove("link/victim") }
        #expect(try Data(contentsOf: outside.appendingPathComponent("victim")) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
    }
}

@Suite struct PeerRequirementTests {
    @Test func adHocNetbootDaemonAcceptsOnlyItsOwner() {
        #expect(PeerRequirement.acceptsPeer(teamIdentifier: nil, peerUID: 501, executableOwnerUID: 501))
        #expect(!PeerRequirement.acceptsPeer(teamIdentifier: nil, peerUID: 502, executableOwnerUID: 501))
        #expect(!PeerRequirement.acceptsPeer(teamIdentifier: nil, peerUID: 501, executableOwnerUID: nil))
        #expect(PeerRequirement.acceptsPeer(teamIdentifier: "ABCDE12345", peerUID: 502, executableOwnerUID: 501))
    }

    @Test func requirementsCompile() {
        for team in ["ABCDE12345", nil] {
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(PeerRequirement.requirement(teamIdentifier: team) as CFString, [], &requirement)
            #expect(status == errSecSuccess, "team \(team ?? "nil"): \(status)")
        }
    }
}
