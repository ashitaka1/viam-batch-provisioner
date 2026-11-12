public import Foundation

/// Supplies the bearer token for Viam calls. `refresh` asks for a token newer
/// than any cached one, after Viam refused the last.
public protocol BearerTokenProvider: Sendable {
    func token(refresh: Bool) async throws -> String
    /// Viam refused a token just refreshed: the login behind it is no longer valid.
    func rejected() async
}

/// The `viam` CLI's token, held in memory only.
public actor CLITokenSource: BearerTokenProvider {
    private let cli: @Sendable () async throws -> ViamCLI
    private let now: @Sendable () -> Date
    private let onSignedOut: @Sendable () async -> Void
    private var cached: (token: String, expiry: Date?)?

    public init(cli: @escaping @Sendable () async throws -> ViamCLI, now: @escaping @Sendable () -> Date = Date.init,
                onSignedOut: @escaping @Sendable () async -> Void = {}) {
        self.cli = cli
        self.now = now
        self.onSignedOut = onSignedOut
    }

    public func token(refresh: Bool) async throws -> String {
        if !refresh, let cached, cached.expiry.map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
            return cached.token
        }
        do {
            let token = try await cli().accessToken()
            cached = (token, JWT.expiry(of: token))
            return token
        } catch ViamCLIError.notLoggedIn {
            cached = nil
            await onSignedOut()
            throw ViamCLIError.notLoggedIn
        }
    }

    /// The CLI still hands out a token Viam refuses, so its login is dead: sign the
    /// session out and let the user sign in again.
    public func rejected() async {
        cached = nil
        await onSignedOut()
    }

    public func clear() {
        cached = nil
    }
}

/// Viam refused the API key itself, as distinct from failing to answer.
public struct APIKeyRefused: Error, Equatable, Sendable {
    public init() {}
}

/// Tokens for one API key, exchanged through `AuthService/Authenticate` and
/// held in memory only.
public actor APIKeyTokenSource: BearerTokenProvider {
    public typealias Authenticate = @Sendable (_ keyID: String, _ key: String) async throws -> String

    private let keyID: String
    private let key: String
    private let authenticate: Authenticate
    private let now: @Sendable () -> Date
    private let onRejected: @Sendable () async -> Void
    private var cached: (token: String, expiry: Date?)?
    /// The exchange in flight, which concurrent callers share.
    private var exchange: Task<String, any Error>?

    /// `authenticate` throws `APIKeyRefused` when Viam refuses the key; so does
    /// `token`, after calling `onRejected`.
    public init(keyID: String, key: String, authenticate: @escaping Authenticate,
                now: @escaping @Sendable () -> Date = Date.init, onRejected: @escaping @Sendable () async -> Void = {}) {
        self.keyID = keyID
        self.key = key
        self.authenticate = authenticate
        self.now = now
        self.onRejected = onRejected
    }

    public func token(refresh: Bool) async throws -> String {
        if !refresh, let cached, cached.expiry.map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
            return cached.token
        }
        if let exchange { return try await finish(exchange) }
        cached = nil
        let task = Task { [authenticate, keyID, key] in try await authenticate(keyID, key) }
        exchange = task
        return try await finish(task)
    }

    private func finish(_ task: Task<String, any Error>) async throws -> String {
        do {
            let token = try await task.value
            if exchange == task {
                exchange = nil
                cached = (token, JWT.expiry(of: token))
            }
            return token
        } catch let refused as APIKeyRefused {
            if exchange == task {
                exchange = nil
                await onRejected()
            }
            throw refused
        } catch {
            if exchange == task { exchange = nil }
            throw error
        }
    }

    /// Viam refused a token just issued for the key: the key is no longer valid.
    public func rejected() async {
        cached = nil
        exchange = nil
        await onRejected()
    }
}

enum JWT {
    /// The JWT's `exp` claim (RFC 7519 §4.1.4); nil when the token isn't a JWT.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
