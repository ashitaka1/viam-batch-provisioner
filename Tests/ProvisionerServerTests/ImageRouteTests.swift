import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import ProvisionerServer
import Testing

private let isoName = "ubuntu-24.04.4-live-server-amd64.iso"

private func imageBytes(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 20) })
}

/// A live server whose boot image is `bytes` under `ubuntu/`, with `m-1` queued.
private func withImageServer(_ bytes: Data,
                             _ body: @Sendable (Provisioner, Int) async throws -> Void) async throws {
    let files = try temporaryDirectory()
    try FileManager.default.createDirectory(at: files.appending(path: "ubuntu"), withIntermediateDirectories: true)
    try bytes.write(to: files.appending(path: "ubuntu/\(isoName)"))
    let dataDirectory = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: files, dataDirectory: dataDirectory,
                                            advertiseAddress: nil, bootImage: "ubuntu/\(isoName)")
    let image = try BootImage(files: files, path: "ubuntu/\(isoName)")
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), bootImage: image, logger: testLogger)
    _ = try await provisioner.provision([request("m-1")])
    let app = try buildApplication(configuration, provisioner: provisioner, logger: testLogger)
    try await app.test(.live) { client in
        try await body(provisioner, client.port!)
    }
}

private func get(_ port: Int, _ path: String) async throws -> (status: UInt, body: Data, length: String?) {
    let response = try await HTTPClient.shared.execute(HTTPClientRequest(url: "http://localhost:\(port)\(path)"),
                                                       timeout: .seconds(30))
    let body = try await response.body.collect(upTo: 1 << 26)
    return (response.status.code, Data(buffer: body), response.headers.first(name: "Content-Length"))
}

@Test func imageRouteRefusesUnknownNameAndFile() async throws {
    let bytes = imageBytes(65_536)
    try await withImageServer(bytes) { _, port in
        #expect(try await get(port, "/pxe/nobody/\(isoName)").status == 404)
        #expect(try await get(port, "/pxe/m-1/other.iso").status == 404)
        #expect(try await get(port, "/pxe/-bad/\(isoName)").status == 404)

        let response = try await get(port, "/pxe/M-1/\(isoName)")
        #expect(response.status == 200)
        #expect(response.length == "65536")
        #expect(response.body == bytes)
    }
}

@Test func imageRouteRecordsSteps() async throws {
    try await withImageServer(imageBytes(3_145_728)) { provisioner, port in
        let response = try await get(port, "/pxe/m-1/\(isoName)")
        #expect(response.status == 200)
        #expect(response.body.count == 3_145_728)

        try await poll(within: .seconds(5)) { await provisioner.machineRecord("m-1")?.downloadBytes == 3_145_728 }
        let entry = try await provisioner.entry("m-1")
        #expect(entry.steps?.last?.step == .installing)
        #expect(entry.downloadBytes == 3_145_728)
        #expect(entry.downloadTotal == 3_145_728)
    }
}

@Test func disconnectRecordsBytesSent() async throws {
    let total = 64 << 20
    try await withImageServer(Data(repeating: 7, count: total)) { provisioner, port in
        let firstPart = TestFlag()
        let download = Task {
            let response = try await HTTPClient.shared.execute(
                HTTPClientRequest(url: "http://localhost:\(port)/pxe/m-1/\(isoName)"), timeout: .seconds(30))
            for try await _ in response.body {
                firstPart.set()
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await poll(within: .seconds(10)) { firstPart.isSet }
        download.cancel()

        try await poll(within: .seconds(4)) { await provisioner.downloads.isEmpty }
        #expect(await provisioner.downloads.isEmpty)
        let record = await provisioner.machineRecord("m-1")
        let sent = try #require(record?.downloadBytes)
        #expect(sent > 0 && sent < total)
        #expect(record?.steps.map(\.step) == ["downloading"])
    }
}
