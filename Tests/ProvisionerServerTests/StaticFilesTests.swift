import Foundation
import Hummingbird
import ProvisionerAPI
import HummingbirdTesting
@testable import ProvisionerServer
import Testing

private let isoBytes = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) })

/// A files root holding a 1 MiB ISO, the report script, and a decoy under `api/`.
private func filesRoot() throws -> URL {
    let root = try temporaryDirectory().appending(path: "files")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appending(path: "ubuntu"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appending(path: "scripts"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appending(path: "api/v1"), withIntermediateDirectories: true)
    try isoBytes.write(to: root.appending(path: "ubuntu/test.iso"))
    try Data("#!/bin/sh\necho report\n".utf8).write(to: root.appending(path: "scripts/install-report.sh"))
    try Data("decoy".utf8).write(to: root.appending(path: "api/v1/queue"))
    return root
}

func makeApp(files: URL? = nil) async throws -> some ApplicationProtocol {
    let dataDirectory = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: try files ?? filesRoot(),
                                            dataDirectory: dataDirectory, advertiseAddress: nil)
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), logger: testLogger)
    return try buildApplication(configuration, provisioner: provisioner, logger: testLogger)
}

@Test func servesFile() async throws {
    try await makeApp().test(.router) { client in
        let response = try await client.execute(uri: "/scripts/install-report.sh", method: .get)
        #expect(response.status == .ok)
        #expect(String(buffer: response.body) == "#!/bin/sh\necho report\n")
    }
}

@Test func headServesLength() async throws {
    try await makeApp().test(.router) { client in
        let response = try await client.execute(uri: "/ubuntu/test.iso", method: .head)
        #expect(response.status == .ok)
        #expect(response.headers[.contentLength] == "1048576")
    }
}

@Test func rangeServesSlice() async throws {
    try await makeApp().test(.router) { client in
        let response = try await client.execute(uri: "/ubuntu/test.iso", method: .get, headers: [.range: "bytes=100-199"])
        #expect(response.status == .partialContent)
        #expect(Data(buffer: response.body) == isoBytes[100..<200])
    }
}

@Test func noDirectoryListing() async throws {
    try await makeApp().test(.router) { client in
        let response = try await client.execute(uri: "/ubuntu/", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func traversalRefused() async throws {
    let root = try filesRoot()
    try Data("secret".utf8).write(to: root.deletingLastPathComponent().appending(path: "outside.txt"))
    try await makeApp(files: root).test(.router) { client in
        for uri in ["/../outside.txt", "/%2e%2e/outside.txt", "/ubuntu/../../outside.txt"] {
            let response = try await client.execute(uri: uri, method: .get)
            #expect(String(buffer: response.body) != "secret", "\(uri) served a file outside the root")
        }
    }
}

@Test func apiPathNotServedFromFiles() async throws {
    try await makeApp().test(.router) { client in
        let response = try await client.execute(uri: "/api/v1/queue", method: .get)
        #expect(response.status == .ok)
        #expect(try JSONDecoder().decode(Schemas.QueueList.self, from: Data(buffer: response.body)).entries.isEmpty)
    }
}
