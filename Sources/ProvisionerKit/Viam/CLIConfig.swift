public import Foundation

/// The `viam` CLI's cached config. Only non-secret keys are read.
public enum CLIConfig {
    public static let defaultPath = "\(NSHomeDirectory())/.viam/cached_cli_config.json"

    /// The Viam app the CLI is logged in to; nil when the file or key is missing.
    public static func baseURL(path: String = defaultPath) -> URL? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["base_url"] as? String else { return nil }
        return URL(string: value)
    }
}
