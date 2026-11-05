import Foundation
import ProvisionerHelperCore
import ProvisionerHelperXPC
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
        #expect(throws: HelperError.invalidPath(path)) { try files.write(Data(), to: path) }
        #expect(throws: HelperError.invalidPath(path)) { try files.remove(path) }
    }

    @Test func removesFileAndIgnoresMissing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("x".utf8), to: "a.cfg")
        try files.remove("a.cfg")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.cfg").path))
        try files.remove("a.cfg")
    }

    @Test func writeOverDirectoryFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try files.write(Data("x".utf8), to: "grub/a.cfg")
        #expect(throws: HelperError.self) { try files.write(Data(), to: "grub") }
    }
}

@Suite struct PeerRequirementTests {
    @Test func teamSignedHelperRequiresSameTeam() {
        #expect(PeerRequirement.requirement(teamIdentifier: "HGCN675G7C")
            == #"anchor apple generic and certificate leaf[subject.OU] = "HGCN675G7C""#)
    }

    @Test func adHocHelperRequiresKnownIdentifiers() {
        #expect(PeerRequirement.requirement(teamIdentifier: nil)
            == #"identifier "com.bringingfire.viam-provisioner.server" or identifier "com.bringingfire.viam-provisioner.helperctl""#)
    }

    @Test func requirementsCompile() {
        for team in ["HGCN675G7C", nil] {
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(PeerRequirement.requirement(teamIdentifier: team) as CFString, [], &requirement)
            #expect(status == errSecSuccess, "team \(team ?? "nil"): \(status)")
        }
    }
}
