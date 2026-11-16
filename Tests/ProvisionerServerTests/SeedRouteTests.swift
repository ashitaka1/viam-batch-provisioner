import AsyncHTTPClient
import Foundation
import HummingbirdTesting
@testable import ProvisionerServer
import Testing

/// A live server with `m-1` queued with `validEnvironment()`; `body` gets its port and token.
private func withSeededServer(_ body: @Sendable (Int, String) async throws -> Void) async throws {
    let files = try temporaryDirectory()
    let dataDirectory = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: files, dataDirectory: dataDirectory,
                                            advertiseAddress: nil)
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), logger: testLogger)
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment())])
    let token = String(try #require(await provisioner.seedPath(for: "m-1")).split(separator: "/").last!)
    try await buildApplication(configuration, provisioner: provisioner, logger: testLogger).test(.live) { client in
        try await body(client.port!, token)
    }
}

/// GETs `path` with `host` as the Host header.
private func get(_ port: Int, _ path: String, host: String = "10.1.0.5:8234")
    async throws -> (status: UInt, body: String, cacheControl: String?) {
    var request = HTTPClientRequest(url: "http://localhost:\(port)\(path)")
    request.headers.replaceOrAdd(name: "Host", value: host)
    let response = try await HTTPClient.shared.execute(request, timeout: .seconds(10))
    let body = try await response.body.collect(upTo: 1 << 20)
    return (response.status.code, String(buffer: body), response.headers.first(name: "Cache-Control"))
}

@Test func seedRouteServesOnceAndMapsFailures() async throws {
    try await withSeededServer { port, token in
        let path = "/machines/by-name/m-1/\(token)/user-data"
        let first = try await get(port, path)
        #expect(first.status == 200)
        #expect(first.body.contains("http://10.1.0.5:8234/scripts/install-report.sh"))
        #expect(first.cacheControl == "no-store")
        #expect(try await get(port, path).status == 404)
        #expect(try await get(port, "/machines/by-name/m-1/\(token)/meta-data").status == 200)
        #expect(try await get(port, "/machines/by-name/m-1/\(token)/").status == 404)
        #expect(try await get(port, "/machines/by-name/m-1/\(String(repeating: "0", count: 32))/meta-data").status == 404)
    }
}

@Test func seedRouteRefusesABadHost() async throws {
    try await withSeededServer { port, token in
        let path = "/machines/by-name/m-1/\(token)/user-data"
        let refused = try await get(port, path, host: "evil$(x)")
        #expect(refused.status == 400)
        let served = try await get(port, path)
        #expect(served.status == 200)
    }
}
