public import Foundation

/// The `viam` CLI's cached config. Of its secrets, only an API-key login's key is
/// read, and only by `apiKey(path:)`.
public enum CLIConfig {
    public static let defaultPath = "\(NSHomeDirectory())/.viam/cached_cli_config.json"

    /// Which login the CLI holds. `viam login` stores a user's tokens under `auth`;
    /// `viam login api-key` stores `{"key_id", "key_crypto"}` there instead.
    public enum Login: Equatable, Sendable {
        case none
        case user
        case apiKey(id: String)
    }

    /// The Viam app the CLI is logged in to; nil when the file or key is missing.
    public static func baseURL(path: String = defaultPath) -> URL? {
        (object(path)?["base_url"] as? String).flatMap(URL.init(string:))
    }

    public static func login(path: String = defaultPath) -> Login {
        guard let auth = object(path)?["auth"] as? [String: Any] else { return .none }
        if let id = auth["key_id"] as? String, !id.isEmpty { return .apiKey(id: id) }
        if let token = auth["access_token"] as? String, !token.isEmpty { return .user }
        return .none
    }

    /// The API key the CLI is logged in with; nil for any other login.
    public static func apiKey(path: String = defaultPath) -> (id: String, key: String)? {
        guard let auth = object(path)?["auth"] as? [String: Any],
              let id = auth["key_id"] as? String, !id.isEmpty,
              let key = auth["key_crypto"] as? String, !key.isEmpty else { return nil }
        return (id, key)
    }

    /// The organization and location set with `viam defaults`.
    public static func defaults(path: String = defaultPath) -> (org: String?, location: String?) {
        let object = object(path)
        func value(_ key: String) -> String? { (object?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return (value("default_org"), value("default_location"))
    }

    private static func object(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
