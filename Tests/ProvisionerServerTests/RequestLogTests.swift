import AsyncHTTPClient
import Foundation
import HummingbirdTesting
@testable import ProvisionerServer
import Testing

@Test func requestsAreLoggedWithTheirStatusAndWithoutTheSeedToken() async throws {
    let files = try temporaryDirectory()
    let dataDirectory = try temporaryDirectory()
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: files, dataDirectory: dataDirectory,
                                            advertiseAddress: nil)
    let provisioner = try Provisioner(dataDirectory: DataDirectory(dataDirectory), logger: testLogger)
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment())])
    let token = String(try #require(await provisioner.seedPath(for: "m-1")).split(separator: "/").last!)
    let log = CapturedLog()
    try await buildApplication(configuration, provisioner: provisioner, logger: log.logger).test(.live) { client in
        for path in ["/machines/by-name/m-1/\(token)/user-data", "/machines/by-name/m-1/wrong/user-data",
                     "//machines/by-name/m-1/\(token)/meta-data", "/api/v1/nope"] {
            var request = HTTPClientRequest(url: "http://localhost:\(client.port!)\(path)?key=value")
            request.headers.replaceOrAdd(name: "Host", value: "10.1.0.5:8234")
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(10))
            _ = try await response.body.collect(upTo: 1 << 20)
        }
    }
    let requests = log.messages.filter { $0.hasPrefix("GET ") }.map { $0.split(separator: " ").prefix(3).joined(separator: " ") }
    // The doubled slash checks only the redaction; its status is the router's business.
    #expect(requests.map { $0.hasPrefix("GET //") ? String($0.dropLast(4)) : $0 } == [
        "GET /machines/by-name/m-1/<token>/user-data 200",
        "GET /machines/by-name/m-1/<token>/user-data 404",
        "GET //machines/by-name/m-1/<token>/meta-data",
        "GET /api/v1/nope 404",
    ])
    #expect(!log.messages.contains { $0.contains(token) || $0.contains("key=value") })
}
