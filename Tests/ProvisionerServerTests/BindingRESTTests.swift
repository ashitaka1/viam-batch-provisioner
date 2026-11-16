import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import ProvisionerServer
import Testing

/// An app whose provisioner has a boot image, with `m-1` and `m-2` queued with an
/// environment and `bare` queued without one.
private func withBindingApp(_ body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
    let (provisioner, dir) = try makeImageProvisioner()
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment()),
                                         request("m-2", environment: validEnvironment()), request("bare")])
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: try temporaryDirectory(),
                                            dataDirectory: dir.root, advertiseAddress: nil)
    try await buildApplication(configuration, provisioner: provisioner, logger: testLogger).test(.router, body)
}

private func bind(_ client: any TestClientProtocol, _ name: String, _ mac: String) async throws -> TestResponse {
    try await client.execute(uri: "/api/v1/queue/\(name)/binding", method: .put,
                             headers: [.contentType: "application/json"],
                             body: ByteBuffer(string: #"{"mac":"\#(mac)"}"#))
}

@Test func bindingOverTheAPI() async throws {
    try await withBindingApp { client in
        let bound = try await bind(client, "m-1", "AA:BB:CC:00:00:01")
        #expect(bound.status == .ok)
        let entry = try StoreCoding.decoder.decode(Schemas.QueueEntry.self, from: Data(buffer: bound.body))
        #expect(entry.mac == "aa:bb:cc:00:00:01")
        #expect(entry.status == .assigned)

        let taken = try await bind(client, "m-2", "aa:bb:cc:00:00:01")
        #expect(taken.status == .conflict)
        #expect(try errorCode(taken) == "mac-bound")

        let unbound = try await client.execute(uri: "/api/v1/queue/m-1/binding", method: .delete)
        #expect(unbound.status == .noContent)
        let after = try await client.execute(uri: "/api/v1/queue/m-1", method: .get)
        let entryAfter = try StoreCoding.decoder.decode(Schemas.QueueEntry.self, from: Data(buffer: after.body))
        #expect(entryAfter.mac == nil)
        #expect(entryAfter.status == .queued)
    }
}

@Test func bindingRefusals() async throws {
    try await withBindingApp { client in
        let unknown = try await bind(client, "m-9", "aa:bb:cc:00:00:01")
        #expect(unknown.status == .notFound)

        let bare = try await bind(client, "bare", "aa:bb:cc:00:00:01")
        #expect(bare.status == .conflict)
        #expect(try errorCode(bare) == "not-bindable")

        let malformed = try await bind(client, "m-1", "aa:bb")
        #expect(malformed.status == .badRequest)
    }
}
