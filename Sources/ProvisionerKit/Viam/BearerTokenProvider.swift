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

/// Tokens from the API key the `viam` CLI is logged in with, exchanged through
/// `AuthService/Authenticate`. The key is read from the CLI's config for each
/// exchange and never kept; the token is held in memory only.
public actor APIKeyTokenSource: BearerTokenProvider {
    public typealias Authenticate = @Sendable (_ keyID: String, _ key: String) async throws -> String

    private let readKey: @Sendable () -> (id: String, key: String)?
    private let authenticate: Authenticate
    private let now: @Sendable () -> Date
    private let onSignedOut: @Sendable () async -> Void
    private var cached: (token: String, expiry: Date?)?

    /// `authenticate` throws `APIKeyRefused` when Viam refuses the key.
    public init(readKey: @escaping @Sendable () -> (id: String, key: String)?, authenticate: @escaping Authenticate,
                now: @escaping @Sendable () -> Date = Date.init, onSignedOut: @escaping @Sendable () async -> Void = {}) {
        self.readKey = readKey
        self.authenticate = authenticate
        self.now = now
        self.onSignedOut = onSignedOut
    }

    public func token(refresh: Bool) async throws -> String {
        if !refresh, let cached, cached.expiry.map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
            return cached.token
        }
        cached = nil
        guard let key = readKey() else {
            await onSignedOut()
            throw ViamCLIError.notLoggedIn
        }
        do {
            let token = try await authenticate(key.id, key.key)
            cached = (token, JWT.expiry(of: token))
            return token
        } catch is APIKeyRefused {
            await onSignedOut()
            throw ViamCLIError.notLoggedIn
        }
    }

    /// Viam refused a token just issued for the key: the key is no longer valid.
    public func rejected() async {
        cached = nil
        await onSignedOut()
    }

    public func clear() {
        cached = nil
    }
}

/// The token source for whichever login the CLI holds, decided on each call so a
/// `viam login` in Terminal takes effect without restarting the app.
public struct CLILoginTokens: BearerTokenProvider {
    private let login: @Sendable () -> CLIConfig.Login
    private let user: CLITokenSource
    private let apiKey: APIKeyTokenSource

    public init(login: @escaping @Sendable () -> CLIConfig.Login, user: CLITokenSource, apiKey: APIKeyTokenSource) {
        self.login = login
        self.user = user
        self.apiKey = apiKey
    }

    public func token(refresh: Bool) async throws -> String {
        if case .apiKey = login() { try await apiKey.token(refresh: refresh) } else { try await user.token(refresh: refresh) }
    }

    public func rejected() async {
        if case .apiKey = login() { await apiKey.rejected() } else { await user.rejected() }
    }

    public func clear() async {
        await user.clear()
        await apiKey.clear()
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
