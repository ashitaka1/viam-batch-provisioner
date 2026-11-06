public import Foundation

/// A named set of everything a batch is provisioned with, kept on this Mac only.
/// Secrets live apart, in `EnvironmentSecrets`; the `has…` flags say which are set.
public struct Environment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var orgID: String?
    /// The org's name when it was chosen, shown when the org is no longer listed.
    public var orgName: String?
    public var locationID: String?
    /// The location's name when it was chosen, shown while Viam can't be reached.
    public var locationName: String?
    public var namePrefix: String
    public var provisionMode: ProvisionMode
    public var username: String
    public var sshPublicKey: String
    public var timezone: String
    public var packages: [String]
    public var wifiSSID: String?
    public var wifiCountry: String?
    public var hasPassword: Bool
    public var hasWifiPassword: Bool
    public var hasTailscaleKey: Bool

    /// The packages in `config/packages.txt.example`, which seeds each environment
    /// the way `build-config.sh` seeds `config/environments/<env>.packages.txt`.
    public static let defaultPackages = [
        "avahi-daemon", "avahi-utils", "network-manager", "openssh-server", "mosh",
        "curl", "jq", "net-tools", "speedtest-cli", "unattended-upgrades",
    ]

    /// A new environment with the defaults: the name as the prefix when Viam would
    /// accept it, this Mac's time zone and region, and the default packages.
    public static func new(name: String, id: UUID = UUID()) -> Environment {
        Environment(
            id: id, name: name, orgID: nil, orgName: nil, locationID: nil, locationName: nil,
            namePrefix: MachineName.prefixProblems(name).isEmpty ? name : "",
            provisionMode: .full, username: "viam", sshPublicKey: "", timezone: TimeZone.current.identifier,
            packages: defaultPackages, wifiSSID: nil, wifiCountry: Locale.current.region?.identifier ?? "US",
            hasPassword: false, hasWifiPassword: false, hasTailscaleKey: false
        )
    }
}

extension ProvisionMode: Codable {}

/// The values an environment keeps in the Keychain. The OS password is stored
/// only as its SHA-512 crypt hash; the plaintext is never kept.
public struct EnvironmentSecrets: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var passwordHash: String?
    public var wifiPassword: String?
    public var tailscaleAuthKey: String?

    public init(passwordHash: String? = nil, wifiPassword: String? = nil, tailscaleAuthKey: String? = nil) {
        self.passwordHash = passwordHash
        self.wifiPassword = wifiPassword
        self.tailscaleAuthKey = tailscaleAuthKey
    }

    public var description: String {
        "EnvironmentSecrets(password: \(passwordHash == nil ? "unset" : "set"), wifi: \(wifiPassword == nil ? "unset" : "set"), "
            + "tailscale: \(tailscaleAuthKey == nil ? "unset" : "set"))"
    }

    public var debugDescription: String { description }
}

/// The settings an environment holds, for tagging problems and the UI.
public enum EnvironmentField: String, CaseIterable, Sendable {
    case name, org, location, namePrefix, provisionMode
    case username, password, sshPublicKey, timezone
    case wifiSSID, wifiPassword, wifiCountry
    case packages, tailscaleAuthKey

    /// The settings the Python server ignores: it renders installs from
    /// `config/site.env`, not from the request's environment. Empty once the
    /// Swift server renders environments.
    public static let ignoredByPythonServer: Set<EnvironmentField> = Set(allCases).subtracting([
        .name, .org, .location, .namePrefix, .provisionMode,
    ])
}

public struct EnvironmentProblem: Sendable, Equatable {
    public var field: EnvironmentField
    public var message: String

    public init(field: EnvironmentField, message: String) {
        self.field = field
        self.message = message
    }
}

public enum EnvironmentError: Error, Sendable, Equatable {
    case invalid([EnvironmentProblem])
}
