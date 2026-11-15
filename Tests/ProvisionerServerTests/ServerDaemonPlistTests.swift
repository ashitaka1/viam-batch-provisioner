#if os(macOS)
import Foundation
import ProvisionerKit
@testable import ProvisionerServer
import Testing

private func launchDaemonPlist(_ name: String) throws -> [String: Any] {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/LaunchDaemons/\(name)")
    return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

@Test func serverDaemonRunsAsTheServerAccountOverItsDirectories() throws {
    let plist = try launchDaemonPlist("\(ServerAccount.label).plist")
    #expect(plist["Label"] as? String == ServerAccount.label)
    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/provisioner-server")
    #expect(plist["UserName"] as? String == ServerAccount.name)
    #expect(plist["GroupName"] as? String == ServerAccount.name)
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["KeepAlive"] as? Bool == true)
    let arguments = Array(try #require(plist["ProgramArguments"] as? [String]).dropFirst())
    #expect(arguments == ["--files", ServerAccount.filesDirectory.path, "--data-dir", ServerAccount.dataDirectory.path])
    let configuration = try ServerConfiguration.parse(arguments)
    #expect(configuration.dataDirectory.path == ServerAccount.dataDirectory.path)
    #expect(configuration.files.path == ServerAccount.filesDirectory.path)
    #expect(configuration.port == ServerAccount.port)
}
#endif
