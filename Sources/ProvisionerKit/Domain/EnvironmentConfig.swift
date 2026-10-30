internal import ProvisionerAPI

public enum ProvisionMode: String, Sendable, Equatable, CaseIterable {
    case full
    case agent
    case osOnly = "os-only"
}

public struct EnvironmentConfig: Sendable, Equatable {
    public struct Wifi: Sendable, Equatable {
        public var ssid: String
        public var password: String?
        public var country: String?

        public init(ssid: String, password: String? = nil, country: String? = nil) {
            self.ssid = ssid
            self.password = password
            self.country = country
        }
    }

    public var provisionMode: ProvisionMode
    public var username: String
    public var passwordHash: String
    public var sshPublicKey: String
    public var timezone: String
    public var packages: [String]
    public var wifi: Wifi?
    public var tailscaleAuthKey: String?

    public init(
        provisionMode: ProvisionMode, username: String, passwordHash: String, sshPublicKey: String,
        timezone: String, packages: [String] = [], wifi: Wifi? = nil, tailscaleAuthKey: String? = nil
    ) {
        self.provisionMode = provisionMode
        self.username = username
        self.passwordHash = passwordHash
        self.sshPublicKey = sshPublicKey
        self.timezone = timezone
        self.packages = packages
        self.wifi = wifi
        self.tailscaleAuthKey = tailscaleAuthKey
    }

    func wire() -> Components.Schemas.Environment {
        Components.Schemas.Environment(
            provisionMode: .init(rawValue: provisionMode.rawValue)!,
            username: username,
            passwordHash: passwordHash,
            sshPublicKey: sshPublicKey,
            timezone: timezone,
            packages: packages.isEmpty ? nil : packages,
            wifi: wifi.map { .init(ssid: $0.ssid, password: $0.password, country: $0.country) },
            tailscaleAuthKey: tailscaleAuthKey
        )
    }
}
