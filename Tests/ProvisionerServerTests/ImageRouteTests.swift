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

/// A live server whose boot image is `bytes` at the URL `body` gets, with `m-1` queued.
private func withImageServer(_ bytes: Data,
                             _ body: @Sendable (Provisioner, Int, URL) async throws -> Void) async throws {
    let files = try temporaryDirectory()
    try FileManager.default.createDirectory(at: files.appending(path: "ubuntu"), withIntermediateDirectories: true)
    let imageURL = files.appending(path: "ubuntu/\(isoName)")
    try bytes.write(to: imageURL)
    let dataDirectory = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: files, dataDirectory: dataDirectory,
                                            advertiseAddress: nil, bootImage: "ubuntu/\(isoName)")
    let image = try BootImage(files: files, path: "ubuntu/\(isoName)")
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), bootImage: image, logger: testLogger)
    _ = try await provisioner.provision([request("m-1")])
    let app = try buildApplication(configuration, provisioner: provisioner, logger: testLogger)
    try await app.test(.live) { client in
        try await body(provisioner, client.port!, imageURL)
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
    try await withImageServer(bytes) { _, port, _ in
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
    let bytes = imageBytes(3_145_728)
    try await withImageServer(bytes) { provisioner, port, _ in
        let response = try await get(port, "/pxe/m-1/\(isoName)")
        #expect(response.status == 200)
        #expect(response.body == bytes)

        try await poll(within: .seconds(5)) { await provisioner.machineRecord("m-1")?.downloadBytes == 3_145_728 }
        let entry = try await provisioner.entry("m-1")
        #expect(entry.steps?.last?.step == .installing)
        #expect(entry.downloadBytes == 3_145_728)
        #expect(entry.downloadTotal == 3_145_728)
    }
}

@Test func imageReplacedInPlaceIsServedWhole() async throws {
    try await withImageServer(imageBytes(65_536)) { provisioner, port, imageURL in
        let replacement = Data(repeating: 9, count: 100_000)
        try replacement.write(to: imageURL)

        let response = try await get(port, "/pxe/m-1/\(isoName)")
        #expect(response.length == "100000")
        #expect(response.body == replacement)
        try await poll(within: .seconds(5)) { await provisioner.machineRecord("m-1")?.downloadBytes == 100_000 }
        #expect(try await provisioner.entry("m-1").downloadTotal == 100_000)
    }
}

/// Starts a download of a 64 MiB image whose client reads the first part and then
/// stops reading for `stall`, and returns once the first part has arrived.
private func stalledDownload(_ port: Int, stall: Duration) async throws -> Task<Void, any Error> {
    let firstPart = TestFlag()
    let download = Task {
        let response = try await HTTPClient.shared.execute(
            HTTPClientRequest(url: "http://localhost:\(port)/pxe/m-1/\(isoName)"), timeout: .seconds(60))
        for try await _ in response.body {
            firstPart.set()
            try await Task.sleep(for: stall)
            return
        }
    }
    try await poll(within: .seconds(10)) { firstPart.isSet }
    return download
}

/// The bytes the record holds once no download is in flight.
private func recordedBytes(_ provisioner: Provisioner) async throws -> Int {
    try await poll(within: .seconds(4)) { await provisioner.downloads.isEmpty }
    #expect(await provisioner.downloads.isEmpty)
    #expect(await provisioner.machineRecord("m-1")?.steps.map(\.step) == ["downloading"])
    return try #require(await provisioner.machineRecord("m-1")?.downloadBytes)
}

@Test func disconnectRecordsBytesSent() async throws {
    let total = 64 << 20
    try await withImageServer(Data(repeating: 7, count: total)) { provisioner, port, _ in
        try await stalledDownload(port, stall: .seconds(30)).cancel()

        let sent = try await recordedBytes(provisioner)
        #expect(sent > 0)
        #expect(sent < total)
    }
}

/// When the test body handed its server over to shut down.
private final class ShutdownStart: @unchecked Sendable {
    private let lock = NSLock()
    private var started: (ContinuousClock.Instant, Provisioner)?

    var value: (ContinuousClock.Instant, Provisioner)? { lock.withLock { started } }
    func set(_ provisioner: Provisioner) { lock.withLock { started = (ContinuousClock.now, provisioner) } }
}

@Test func gracefulShutdownEndsADownload() async throws {
    let total = 64 << 20
    let shutdown = ShutdownStart()
    try await withImageServer(Data(repeating: 7, count: total)) { provisioner, port, _ in
        _ = try await stalledDownload(port, stall: .seconds(15))
        shutdown.set(provisioner)
    }
    let (started, provisioner) = try #require(shutdown.value)
    let elapsed = ContinuousClock.now - started

    #expect(elapsed < .seconds(5), "the server took \(elapsed) to shut down")
    let sent = try await recordedBytes(provisioner)
    #expect(sent > 0)
    #expect(sent < total)
}
