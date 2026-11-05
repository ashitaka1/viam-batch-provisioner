import AsyncHTTPClient
import Foundation
import NIOCore
@testable import ProvisionerKit
@testable import ProvisionerServer
import Testing

private func post(_ port: Int, _ json: String) async throws {
    var request = HTTPClientRequest(url: "http://localhost:\(port)/api/v1/install-reports")
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.body = .bytes(ByteBuffer(string: json))
    let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
    #expect(response.status.code == 200)
}

@Test func restartKeepsQueueAndJournal() async throws {
    let dataDirectory = try temporaryDirectory()
    try await withLiveServer(dataDirectory: dataDirectory) { client, test, _ in
        _ = try await client.provision([ProvisionRequest(name: "m-1"), ProvisionRequest(name: "m-2")])
        try await post(test.port!, #"{"kind":"progress","stage":"late-commands","name":"m-1"}"#)
        try await post(test.port!, #"{"kind":"progress","stage":"done","name":"m-1"}"#)
    }

    try await withLiveServer(dataDirectory: dataDirectory) { client, test, _ in
        let snapshot = try await client.queue()
        #expect(snapshot.entries.map(\.name) == ["m-1", "m-2"])
        #expect(snapshot.entries.map(\.status) == [.installed, .queued])
        #expect(snapshot.lastEventID == 3)

        try await post(test.port!, #"{"kind":"progress","stage":"identity","name":"m-2"}"#)

        let frames = try await client.eventFrames(after: 0)
        let ids = try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                var ids: [String] = []
                for try await frame in frames {
                    if let id = frame.id { ids.append(id) }
                    if ids.count == 4 { break }
                }
                return ids
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return []
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        #expect(ids == ["1", "2", "3", "4"])
    }
}
