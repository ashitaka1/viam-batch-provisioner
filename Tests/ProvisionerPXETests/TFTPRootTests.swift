import Foundation
import Testing
@testable import ProvisionerPXE

@Suite struct TFTPRootTests {
    let directory: URL
    let root: TFTPRoot

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("grub"), withIntermediateDirectories: true)
        try Data("set timeout=5\n".utf8).write(to: directory.appendingPathComponent("grub/grub.cfg"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        root = TFTPRoot(directory)
    }

    @Test(arguments: ["grub/grub.cfg", "/grub/grub.cfg"])
    func resolvesNested(filename: String) throws {
        let url = try #require(root.resolve(filename))
        #expect(try String(contentsOf: url, encoding: .utf8) == "set timeout=5\n")
    }

    @Test(arguments: ["../etc/hosts", "grub/../../etc/hosts", "escape", "grub", "missing", ""])
    func rejects(filename: String) {
        #expect(root.resolve(filename) == nil, "served \(filename)")
    }
}
