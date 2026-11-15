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

@Test func netbootFlagIsGone() {
    #expect { try ServerConfiguration.parse(["--files", "/x", "--netboot"]) } throws: {
        "\($0)" == "unknown option --netboot"
    }
}

/// A fresh data directory, holding `pxe.json` with `contents` when given.
private func dataDirectory(pxeJSON contents: String? = nil) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "data-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let contents { try Data(contents.utf8).write(to: directory.appending(path: "pxe.json")) }
    return directory
}

@Test func pxeFlagsSetTheSettings() throws {
    let data = try dataDirectory()
    let configuration = try ServerConfiguration.parse(
        ["--files", "/x", "--data-dir", data.path, "--pxe-interface", "en7", "--boot-file", "shimx64.efi"])
    #expect(configuration.pxe == PXESettings(interface: "en7", bootFile: "shimx64.efi"))
    #expect(configuration.tftpRoot == data.appending(path: "tftp"))
}

@Test func bootFileWithoutInterfaceIsRejected() throws {
    let data = try dataDirectory()
    #expect(throws: ConfigurationError.self) {
        try ServerConfiguration.parse(["--files", "/x", "--data-dir", data.path, "--boot-file", "shimx64.efi"])
    }
}

@Test func pxeSettingsFileIsRead() throws {
    let data = try dataDirectory(pxeJSON: #"{"interface": "en3"}"#)
    let configuration = try ServerConfiguration.parse(["--files", "/x", "--data-dir", data.path]).readingPXESettingsFile()
    #expect(configuration.pxe == PXESettings(interface: "en3", bootFile: "grubx64.efi"))
}

@Test func flagsWinOverTheSettingsFile() throws {
    let data = try dataDirectory(pxeJSON: #"{"interface": "en3", "boot_file": "shimx64.efi"}"#)
    let configuration = try ServerConfiguration.parse(["--files", "/x", "--data-dir", data.path, "--pxe-interface", "en7"])
        .readingPXESettingsFile()
    #expect(configuration.pxe == PXESettings(interface: "en7", bootFile: "grubx64.efi"))
}

@Test func noSettingsMeansNoPXE() throws {
    let data = try dataDirectory()
    #expect(try ServerConfiguration.parse(["--files", "/x", "--data-dir", data.path]).readingPXESettingsFile().pxe == nil)
}

@Test(arguments: [#"{"interface": 3}"#, #"{"interface": "en0", "extra": 1}"#, "not json", "{}"])
func malformedSettingsFileNamesIt(contents: String) throws {
    let data = try dataDirectory(pxeJSON: contents)
    #expect { try ServerConfiguration.parse(["--files", "/x", "--data-dir", data.path]).readingPXESettingsFile() } throws: {
        $0 is ConfigurationError && "\($0)".contains(data.appending(path: "pxe.json").path)
    }
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
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(base + ["--boot-image", "ubuntu"]) }
    #expect(try ServerConfiguration.parse(base + ["--boot-image", "ubuntu/x.iso"]).bootImage == "ubuntu/x.iso")
}
