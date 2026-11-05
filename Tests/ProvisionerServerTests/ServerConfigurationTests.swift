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

@Test(arguments: [[String](), ["--files"], ["--files", "/x", "--bogus"], ["--files", "/x", "--port", "http"]])
func badFlagsThrow(arguments: [String]) {
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.parse(arguments) }
}
