public import Foundation

/// Holds environments and their secrets. Saving an environment already present
/// replaces it; its `has…` flags always follow the secrets the store holds.
public protocol EnvironmentStore: Sendable {
    /// Sorted by name, ignoring case.
    func all() throws -> [Environment]
    /// Empty secrets for an environment that has none, or isn't stored.
    func secrets(id: UUID) throws -> EnvironmentSecrets
    /// Nil `secrets` keeps the ones stored.
    func save(_ environment: Environment, secrets: EnvironmentSecrets?) throws
    /// Removing an environment that isn't stored does nothing.
    func remove(id: UUID) throws
}

public enum EnvironmentStoreError: Error, Sendable, Equatable, LocalizedError {
    case unreadable(path: String, reason: String)
    case unwritable(path: String, reason: String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason): "Couldn't read the environments in \(path): \(reason)"
        case .unwritable(let path, let reason): "Couldn't save the environments to \(path): \(reason)"
        case .keychain(let status): "Couldn't use the Keychain for an environment's secrets (\(status))."
        }
    }
}

extension Environment {
    func flagged(by secrets: EnvironmentSecrets) -> Environment {
        var environment = self
        environment.hasPassword = !(secrets.passwordHash ?? "").isEmpty
        environment.hasWifiPassword = !(secrets.wifiPassword ?? "").isEmpty
        environment.hasTailscaleKey = !(secrets.tailscaleAuthKey ?? "").isEmpty
        return environment
    }
}

extension [Environment] {
    func sortedByName() -> [Environment] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
