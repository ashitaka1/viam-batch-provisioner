import Foundation
@testable import ProvisionerServer
import Testing

@Test func parseFlags() throws {
    let configuration = try ServerConfiguration.parse(
        ["--port", "9000", "--files", "/x", "--data-dir", "/d", "--advertise-address", "10.0.0.2:9000", "--bind", "127.0.0.1"])

    #expect(configuration.port == 9000)
    #expect(configuration.bind == "127.0.0.1")
    #expect(configuration.files.path == "/x")
    #expect(configuration.dataDirectory.path == "/d")
    #expect(configuration.advertiseAddress == "10.0.0.2:9000")
}

@Test func flagDefaults() throws {
    let configuration = try ServerConfiguration.parse(["--files", "/x"])

    #expect(configuration.port == 8234)
    #expect(configuration.bind == "0.0.0.0")
    #expect(configuration.dataDirectory == ServerConfiguration.defaultDataDirectory)
    #expect(configuration.advertiseAddress == nil)
}

@Test func helperFlagTakesNoValue() throws {
    #if canImport(ProvisionerHelperXPC)
    #expect(try ServerConfiguration.parse(["--files", "/x", "--helper"]).linksHelper)
    #expect(try ServerConfiguration.parse(["--helper", "--files", "/x"]).linksHelper)
    #expect(try !ServerConfiguration.parse(["--files", "/x"]).linksHelper)
    #else
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(["--files", "/x", "--helper"]) }
    #endif
}

@Test(arguments: [[String](), ["--files"], ["--files", "/x", "--bogus"], ["--files", "/x", "--port", "http"]])
func badFlagsThrow(arguments: [String]) {
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(arguments) }
}

/// A fresh directory holding `files/`.
private func scratchTree() throws -> (root: URL, files: URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "config-\(UUID().uuidString)")
    let files = root.appending(path: "files")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    return (root, files)
}

@Test(arguments: ["files", "files/data", "files/a/b", "other/../files/data"])
func dataDirectoryInsideFilesIsRefused(relative: String) throws {
    let (root, files) = try scratchTree()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: ConfigurationError.self) {
        try ServerConfiguration.parse(["--files", files.path, "--data-dir", root.appending(path: relative).path])
    }
}

@Test func dataDirectoryReachingFilesThroughASymlinkIsRefused() throws {
    let (root, files) = try scratchTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)

    #expect(throws: ConfigurationError.self) {
        try ServerConfiguration.parse(["--files", files.path, "--data-dir", link.appending(path: "data").path])
    }
}

@Test func filesReachedThroughASymlinkStillContainTheDataDirectory() throws {
    let (root, files) = try scratchTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)

    #expect(throws: ConfigurationError.self) {
        try ServerConfiguration.parse(["--files", link.path, "--data-dir", files.appending(path: "data").path])
    }
}

@Test(arguments: ["data", "files-data", "files2/data"])
func dataDirectoryBesideFilesIsAccepted(relative: String) throws {
    let (root, files) = try scratchTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = try ServerConfiguration.parse(
        ["--files", files.path, "--data-dir", root.appending(path: relative).path])

    #expect(configuration.dataDirectory.path == root.appending(path: relative).path)
}

@Test func bootImageMustBeUnderFiles() throws {
    let (root, files) = try scratchTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("iso".utf8).write(to: root.appending(path: "x.iso"))
    try FileManager.default.createDirectory(at: files.appending(path: "ubuntu"), withIntermediateDirectories: true)
    try Data("iso".utf8).write(to: files.appending(path: "ubuntu/x.iso"))
    let base = ["--files", files.path, "--data-dir", root.appending(path: "data").path]

    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(base + ["--boot-image", "../x.iso"]) }
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(base + ["--boot-image", "ubuntu/missing.iso"]) }
    #expect(try ServerConfiguration.parse(base + ["--boot-image", "ubuntu/x.iso"]).bootImage == "ubuntu/x.iso")
}
