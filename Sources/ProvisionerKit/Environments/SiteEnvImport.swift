public import Foundation

/// Reads `config/site.env`-style files the way `scripts/lib/site-env.sh`'s
/// `read_setting` does, without running them as shell.
public enum SiteEnv {
    /// `KEY=value` lines, with an optional `export `. Quote characters are
    /// dropped and the last line for a key wins, as in `read_setting`.
    public static func parse(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = Substring(rawLine)
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count) }
            guard let match = line.wholeMatch(of: /([A-Za-z_][A-Za-z0-9_]*)=(.*)/) else { continue }
            settings[String(match.1)] = String(match.2).filter { $0 != "\"" && $0 != "'" }
        }
        return settings
    }
}

public enum SiteEnvImportError: Error, Sendable, Equatable, LocalizedError {
    case missingSSHKey(String)
    case missingPassword
    case unknownProvisionMode(String)

    public var errorDescription: String? {
        switch self {
        case .missingSSHKey(let path): "No SSH public key at \(path) (SSH_PUBLIC_KEY_FILE)."
        case .missingPassword: "The file has no PASSWORD."
        case .unknownProvisionMode(let mode): "PROVISION_MODE \"\(mode)\" isn't full, agent or os-only."
        }
    }
}

/// Turns a `config/environments/<env>.env` and its packages file into an
/// environment. Viam API keys in the file are ignored: the app acts in an org
/// only through a key paired with `just pair-app`.
public enum SiteEnvImport {
    public static func environment(
        name: String, settings: [String: String], packagesText: String?,
        readFile: (String) throws -> String, home: String
    ) throws(SiteEnvImportError) -> (Environment, EnvironmentSecrets) {
        func value(_ key: String) -> String? {
            settings[key].flatMap { $0.isEmpty ? nil : $0 }
        }

        // Missing settings take the scripts' defaults (build-config.sh, provision-batch.sh).
        var environment = Environment.new(name: name)
        let mode = value("PROVISION_MODE") ?? ProvisionMode.osOnly.rawValue
        guard let parsed = ProvisionMode(rawValue: mode) else { throw .unknownProvisionMode(mode) }
        environment.provisionMode = parsed
        if let username = value("USERNAME") { environment.username = username }
        environment.timezone = value("TIMEZONE") ?? "America/New_York"
        environment.wifiSSID = value("WIFI_SSID")
        if let country = value("WIFI_COUNTRY") { environment.wifiCountry = country }
        environment.orgID = value("VIAM_ORG_ID")
        environment.locationID = value("VIAM_LOCATION_ID")

        let keyPath = (value("SSH_PUBLIC_KEY_FILE") ?? "~/.ssh/id_ed25519.pub").replacing(/^~/, with: home)
        guard let key = try? readFile(keyPath) else { throw .missingSSHKey(keyPath) }
        environment.sshPublicKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if let packagesText {
            // The first word of each line, as build-config.sh's read_packages takes it.
            environment.packages = packagesText.split(whereSeparator: \.isNewline)
                .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
                .filter { !$0.hasPrefix("#") }
        }

        guard let password = value("PASSWORD") else { throw .missingPassword }
        let secrets = EnvironmentSecrets(
            passwordHash: SHA512Crypt.hash(password),
            wifiPassword: environment.wifiSSID == nil ? nil : value("WIFI_PASSWORD"),
            tailscaleAuthKey: value("TAILSCALE_AUTH_KEY"))
        return (environment, secrets)
    }
}

extension SiteEnvImport {
    /// Imports `<dir>/<env>.env`, with `<dir>/<env>.packages.txt` when present, as
    /// the environment named `<env>`. An environment already named that, in any
    /// case, is replaced and keeps its ID.
    @discardableResult
    public static func importFile(at file: URL, into store: any EnvironmentStore, home: String = NSHomeDirectory()) throws -> Environment {
        let name = file.deletingPathExtension().lastPathComponent
        let text = try String(contentsOf: file, encoding: .utf8)
        let packagesFile = file.deletingLastPathComponent().appendingPathComponent("\(name).packages.txt")
        let packagesText = try? String(contentsOf: packagesFile, encoding: .utf8)
        var (environment, secrets) = try environment(
            name: name, settings: SiteEnv.parse(text), packagesText: packagesText,
            readFile: { try String(contentsOfFile: $0, encoding: .utf8) }, home: home)
        if let existing = try store.all().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            environment.id = existing.id
            environment.name = existing.name
        }
        try store.save(environment, secrets: secrets)
        return try store.all().first { $0.id == environment.id } ?? environment
    }
}
