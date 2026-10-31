import Foundation
import SwiftProtobuf

public enum ViamError: Error, Equatable, Sendable {
    /// gRPC status 16.
    case unauthenticated(String)
    /// gRPC status 7.
    case permissionDenied(String)
    case status(code: Int, message: String)
    case transport(String)
    case malformedResponse
}

/// Unary gRPC-web calls over URLSession, per the gRPC-web wire format
/// (github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md): each message is a
/// frame of a flag byte, a big-endian UInt32 length and the bytes; a frame with
/// flag 0x80 carries the trailers as HTTP/1-style header lines. A trailers-only
/// response puts grpc-status in the HTTP headers instead.
struct GRPCWeb: Sendable {
    let baseURL: URL
    let session: URLSession

    func unary<Response: SwiftProtobuf.Message>(
        _ method: String, _ request: some SwiftProtobuf.Message, metadata: [String: String] = [:]
    ) async throws -> Response {
        var urlRequest = URLRequest(url: baseURL.appending(path: method))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/grpc-web+proto", forHTTPHeaderField: "content-type")
        urlRequest.setValue("1", forHTTPHeaderField: "x-grpc-web")
        for (name, value) in metadata { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = Self.frame(0, try request.serializedData())

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ViamError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ViamError.malformedResponse }
        guard http.statusCode == 200 else { throw ViamError.transport("HTTP \(http.statusCode)") }

        var message: Data?
        var trailers: [String: String] = [:]
        var rest = data[...]
        while !rest.isEmpty {
            guard rest.count >= 5 else { throw ViamError.malformedResponse }
            let flag = rest[rest.startIndex]
            let length = rest.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
            let start = rest.startIndex + 5
            guard rest.count - 5 >= length else { throw ViamError.malformedResponse }
            let payload = rest[start..<start + length]
            if flag & 0x80 != 0 {
                trailers.merge(Self.parseTrailers(payload)) { _, new in new }
            } else if message == nil {
                message = Data(payload)
            }
            rest = rest[(start + length)...]
        }

        let headerStatus = http.value(forHTTPHeaderField: "grpc-status")
        let code = Int(headerStatus ?? trailers["grpc-status"] ?? "")
        let rawMessage = headerStatus != nil ? http.value(forHTTPHeaderField: "grpc-message") : trailers["grpc-message"]
        let statusMessage = (rawMessage ?? "").removingPercentEncoding ?? rawMessage ?? ""
        switch code {
        case 0:
            guard let message else { throw ViamError.malformedResponse }
            do { return try Response(serializedBytes: message) } catch { throw ViamError.malformedResponse }
        case 16: throw ViamError.unauthenticated(statusMessage)
        case 7: throw ViamError.permissionDenied(statusMessage)
        case let code?: throw ViamError.status(code: code, message: statusMessage)
        case nil: throw ViamError.malformedResponse
        }
    }

    static func frame(_ flag: UInt8, _ payload: Data) -> Data {
        var data = Data([flag])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    static func parseTrailers(_ payload: Data) -> [String: String] {
        var trailers: [String: String] = [:]
        for line in String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            trailers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return trailers
    }
}
