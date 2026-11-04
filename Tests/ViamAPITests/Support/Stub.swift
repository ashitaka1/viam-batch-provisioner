import Foundation
import ProvisionerKit
import SwiftProtobuf
@testable import ViamAPI

// MARK: - Stub server

/// Serves canned gRPC-web responses per host; each test uses its own host so
/// tests can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["content-type": "application/grpc-web+proto"]
        var body = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var handlers: [String: (URLRequest, Data) -> Reply] = [:]
    static let lock = NSLock()

    static func register(_ handler: @escaping (URLRequest, Data) -> Reply) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { handlers[host] = handler }
        return URL(string: "https://\(host)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url!.host!] }!
        let reply = handler(request, Self.body(of: request))
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}()

func frame(_ flag: UInt8, _ payload: Data) -> Data {
    var data = Data([flag])
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
    return data + payload
}

func ok(_ message: some SwiftProtobuf.Message) -> StubProtocol.Reply {
    StubProtocol.Reply(body: frame(0, try! message.serializedData()) + frame(0x80, Data("grpc-status:0\r\ngrpc-message:\r\n".utf8)))
}

func trailerStatus(_ code: Int, _ message: String) -> StubProtocol.Reply {
    StubProtocol.Reply(body: frame(0x80, Data("grpc-status:\(code)\r\ngrpc-message:\(message)\r\n".utf8)))
}

func unframe<M: SwiftProtobuf.Message>(_ type: M.Type, _ body: Data) throws -> M {
    try M(serializedBytes: body.dropFirst(5))
}

func authenticated(token: String = "tok") -> Proto_Rpc_V1_AuthenticateResponse {
    var response = Proto_Rpc_V1_AuthenticateResponse()
    response.accessToken = token
    return response
}

func organization(_ id: String, _ name: String) -> Viam_App_V1_GetOrganizationResponse {
    var response = Viam_App_V1_GetOrganizationResponse()
    response.organization.id = id
    response.organization.name = name
    return response
}

let credential = OrgCredential(
    PairingPayload(orgID: "o1", orgName: "Acme", keyID: "kid", key: "kval", keyName: "provisioner-app studio 2026-10-31"),
    addedAt: Date(timeIntervalSince1970: 0))

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// Hands out `tokens` in order, repeating the last, or throws `failure`. Records
/// each `refresh` flag and each `rejected()`.
actor ScriptedTokens: BearerTokenProvider {
    private var tokens: [String]
    private let failure: (any Error)?
    private(set) var refreshes: [Bool] = []
    private(set) var rejections = 0

    init(_ tokens: [String]) {
        self.tokens = tokens
        failure = nil
    }

    init(failing failure: any Error) {
        tokens = []
        self.failure = failure
    }

    func token(refresh: Bool) async throws -> String {
        refreshes.append(refresh)
        if let failure { throw failure }
        return tokens.count > 1 ? tokens.removeFirst() : tokens[0]
    }

    func rejected() async { rejections += 1 }
}
