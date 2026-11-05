import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import ProvisionerAPI
@testable import ProvisionerKit
@testable import ProvisionerServer
import Testing

/// A live server on an ephemeral port, its data directory, and a ProvisionerKit client for it.
func withLiveServer(dataDirectory: URL? = nil, streamOptions: StreamOptions = .init(),
                    _ body: @Sendable (ProvisionerClient, any TestClientProtocol, URL) async throws -> Void) async throws {
    let dataDirectory = try dataDirectory ?? temporaryDirectory()
    let files = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: files, dataDirectory: dataDirectory,
                                            advertiseAddress: "127.0.0.1:8234")
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), logger: testLogger)
    let app = try buildApplication(configuration, provisioner: provisioner, logger: testLogger, streamOptions: streamOptions)
    try await app.test(.live) { client in
        let base = URL(string: "http://localhost:\(client.port!)")!
        try await body(ProvisionerClient(baseURL: base), client, dataDirectory)
    }
}

func errorCode(_ response: TestResponse) throws -> String {
    try JSONDecoder().decode(Schemas._Error.self, from: Data(buffer: response.body)).error.code.rawValue
}

/// The status and code of the ProvisionerKit server error `body` throws, or nil.
func serverError(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch let ProvisionerError.server(status, code, _, _) {
        return "\(status) \(code)"
    } catch {
        return "\(error)"
    }
}

private func json(_ text: String) -> ByteBuffer { ByteBuffer(string: text) }

private let jsonHeaders: HTTPFields = [.contentType: "application/json"]

@Test func provisionThenQueue() async throws {
    try await withLiveServer { provisioner, _, _ in
        let results = try await provisioner.provision([ProvisionRequest(name: "m-1"), ProvisionRequest(name: "m-2")])
        #expect(results.map(\.added) == [true, true])

        let snapshot = try await provisioner.queue()
        #expect(snapshot.entries.map(\.name) == ["m-1", "m-2"])
        #expect(snapshot.entries.map(\.status) == [.queued, .queued])
        #expect(snapshot.lastEventID == 0)
    }
}

@Test func entryAndRemove() async throws {
    try await withLiveServer { provisioner, _, _ in
        _ = try await provisioner.provision([ProvisionRequest(name: "m-1")])
        #expect(try await provisioner.entry(named: "M-1").name == "m-1")

        try await provisioner.remove(named: "m-1")

        #expect(await serverError { _ = try await provisioner.entry(named: "m-1") } == "404 not-found")
    }
}

@Test func removeWhileInstallingConflicts() async throws {
    try await withLiveServer { provisioner, client, _ in
        _ = try await provisioner.provision([ProvisionRequest(name: "m-1")])
        _ = try await client.execute(uri: "/api/v1/install-reports", method: .post, headers: jsonHeaders,
                                     body: json(#"{"kind":"progress","stage":"tooling","name":"m-1"}"#))

        #expect(await serverError { try await provisioner.remove(named: "m-1") } == "409 already-assigned")
    }
}

@Test func statusReportsHTTPOnly() async throws {
    try await withLiveServer { provisioner, _, _ in
        _ = try await provisioner.provision([ProvisionRequest(name: "m-1")])

        let status = try await provisioner.status()

        #expect(status.services == .init(http: .up))
        #expect(status.apiVersion == "v1")
        #expect(status.address == "127.0.0.1:8234")
        #expect(status.queue?.queued == 1)
        #expect(!status.serverName.isEmpty)
    }
}

@Test func reportByNameDrivesInstalled() async throws {
    try await withLiveServer { provisioner, client, _ in
        _ = try await provisioner.provision([ProvisionRequest(name: "m-1")])

        let response = try await client.execute(uri: "/api/v1/install-reports", method: .post, headers: jsonHeaders,
                                                body: json(#"{"kind":"progress","stage":"done","name":"m-1"}"#))

        #expect(response.status == .ok)
        #expect(try JSONDecoder().decode(Schemas.InstallReportResult.self, from: Data(buffer: response.body)).result == .recorded)
        #expect(try await provisioner.entry(named: "m-1").status == .installed)
    }
}

@Test func reportForUnknownMachineIs404() async throws {
    try await withLiveServer { _, client, _ in
        let response = try await client.execute(uri: "/api/v1/install-reports", method: .post, headers: jsonHeaders,
                                                body: json(#"{"kind":"progress","stage":"done","mac":"aa:bb:cc:dd:ee:ff"}"#))
        #expect(response.status == .notFound)
        #expect(try errorCode(response) == "not-found")
    }
}

@Test func hostileNames() async throws {
    try await withLiveServer { _, client, dataDirectory in
        let before = try FileManager.default.subpathsOfDirectory(atPath: dataDirectory.path).sorted()
        for (method, uri) in [(HTTPRequest.Method.get, "/api/v1/queue/..%2Fx"), (.delete, "/api/v1/queue/..%2Fx"),
                              (.get, "/api/v1/queue/" + String(repeating: "a", count: 61)),
                              (.delete, "/api/v1/queue/a%20b")] {
            let response = try await client.execute(uri: uri, method: method)
            #expect(response.status == .badRequest, "\(method) \(uri)")
            #expect(try errorCode(response) == "invalid-name", "\(method) \(uri)")
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: dataDirectory.path).sorted() == before)
    }
}

@Test func malformedBodies() async throws {
    try await withLiveServer { _, client, _ in
        let cases: [(String, HTTPFields, ByteBuffer, HTTPResponse.Status, String)] = [
            ("/api/v1/provision", jsonHeaders, json("{"), .badRequest, "invalid-json"),
            ("/api/v1/provision", jsonHeaders, json(#"{"name":"a"}"#), .badRequest, "invalid-request"),
            ("/api/v1/provision", jsonHeaders, json("[]"), .badRequest, "invalid-request"),
            ("/api/v1/provision", jsonHeaders, ByteBuffer(repeating: UInt8(ascii: " "), count: 5 * 1024 * 1024 + 1),
             .contentTooLarge, "payload-too-large"),
            ("/api/v1/install-reports", jsonHeaders, ByteBuffer(repeating: UInt8(ascii: " "), count: 16 * 1024 + 1),
             .contentTooLarge, "payload-too-large"),
            ("/api/v1/install-reports", jsonHeaders, json(#"{"kind":"progress","stage":"bogus","name":"m"}"#),
             .badRequest, "invalid-request"),
        ]
        for (uri, headers, body, status, code) in cases {
            let response = try await client.execute(uri: uri, method: .post, headers: headers, body: body)
            #expect(response.status == status, "\(uri) with \(body.readableBytes) bytes")
            #expect(try errorCode(response) == code, "\(uri) with \(body.readableBytes) bytes")
        }
    }
}

@Test func chunkedPostNeedsLength() async throws {
    try await withLiveServer { _, client, _ in
        var request = HTTPClientRequest(url: "http://localhost:\(client.port!)/api/v1/provision")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        let chunks = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: #"[{"name":"m-1"}]"#))
            continuation.finish()
        }
        request.body = .stream(chunks, length: .unknown)

        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(10))
        let body = try await response.body.collect(upTo: 1 << 16)

        #expect(response.status.code == 411)
        #expect(try JSONDecoder().decode(Schemas._Error.self, from: Data(buffer: body)).error.code == .lengthRequired)
    }
}

@Test func unknownAPIPath() async throws {
    try await withLiveServer { _, client, _ in
        let response = try await client.execute(uri: "/api/v1/nope", method: .get)
        #expect(response.status == .notFound)
        #expect(try errorCode(response) == "not-found")
    }
}
