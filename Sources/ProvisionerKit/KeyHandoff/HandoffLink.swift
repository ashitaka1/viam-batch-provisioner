public import Foundation

/// Where the handoff command listens. Opened as a URL on the same Mac, scanned
/// as a QR code from another device. Carries nothing secret.
public struct HandoffLink: Sendable, Equatable {
    public static let scheme = "viam-provisioner"

    public var host: String
    public var port: Int
    public var nonce: HandoffNonce

    public init(host: String, port: Int, nonce: HandoffNonce) {
        self.host = host
        self.port = port
        self.nonce = nonce
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "handoff"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "nonce", value: nonce.base64URL),
        ]
        return components.url!
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == "handoff" else { throw HandoffError.invalidLink }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let host = items["host"], !host.isEmpty,
              let port = items["port"].flatMap(Int.init), (1...65_535).contains(port),
              let nonce = items["nonce"].flatMap(HandoffNonce.init(base64URL:)) else { throw HandoffError.invalidLink }
        self.init(host: host, port: port, nonce: nonce)
    }

    /// The QR code carries the link itself.
    public var qrPayload: String { url.absoluteString }

    public init(qrPayload: String) throws {
        guard let url = URL(string: qrPayload) else { throw HandoffError.invalidLink }
        try self.init(url: url)
    }

    /// The command's base URL for this session.
    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        return components.url!
    }
}
