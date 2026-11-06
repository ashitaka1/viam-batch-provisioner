import Foundation
import Testing
@testable import ProvisionerPXE

/// The root sits in a scratch directory beside a secret file and a sibling whose name has
/// the root's name as a prefix, so every rejection below exists and is outside the root.
@Suite final class TFTPRootTests {
    let base: URL
    let root: TFTPRoot

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("grub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("rootx"), withIntermediateDirectories: true)
        try Data("set timeout=5\n".utf8).write(to: directory.appendingPathComponent("grub/grub.cfg"))
        try Data("secret\n".utf8).write(to: base.appendingPathComponent("secret.txt"))
        try Data("sibling\n".utf8).write(to: base.appendingPathComponent("rootx/f"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape"),
            withDestinationURL: base.appendingPathComponent("secret.txt")
        )
        root = TFTPRoot(directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @Test(arguments: ["grub/grub.cfg", "/grub/grub.cfg"])
    func resolvesNested(filename: String) throws {
        let url = try #require(root.resolve(filename))
        #expect(try String(contentsOf: url, encoding: .utf8) == "set timeout=5\n")
    }

    @Test(arguments: ["../secret.txt", "grub/../../secret.txt", "../rootx/f", "escape"])
    func rejectsOutsideRoot(filename: String) {
        #expect(root.resolve(filename) == nil, "served \(filename) from outside the root")
    }

    @Test(arguments: ["grub", "missing", ""])
    func rejectsNonFiles(filename: String) {
        #expect(root.resolve(filename) == nil, "served \(filename)")
    }

    /// Opening a FIFO blocks until a writer appears, which would stall the event loop.
    @Test func rejectsFIFO() throws {
        let fifo = root.url.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o644) == 0, "mkfifo failed: errno \(errno)")
        #expect(root.resolve("pipe") == nil, "served a FIFO")
    }
}
