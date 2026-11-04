public import Foundation
import Security

/// Where an environment's secrets are kept, one entry per environment ID.
public protocol EnvironmentSecretsVault: Sendable {
    /// Nil when the environment has none.
    func read(id: UUID) throws -> EnvironmentSecrets?
    func write(_ secrets: EnvironmentSecrets, id: UUID, label: String) throws
    /// Deleting secrets that aren't there does nothing.
    func delete(id: UUID) throws
}

/// Environments in one JSON file, written atomically; their secrets in a vault,
/// the Keychain by default.
public struct FileEnvironmentStore: EnvironmentStore {
    public let file: URL
    public let vault: any EnvironmentSecretsVault

    public static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "Viam Provisioner/environments.json")
    }

    public init(file: URL = Self.defaultFile, vault: any EnvironmentSecretsVault = KeychainSecretsVault()) {
        self.file = file
        self.vault = vault
    }

    public func all() throws -> [Environment] {
        try read().sortedByName()
    }

    public func secrets(id: UUID) throws -> EnvironmentSecrets {
        try vault.read(id: id) ?? EnvironmentSecrets()
    }

    public func save(_ environment: Environment, secrets: EnvironmentSecrets?) throws {
        if let secrets { try vault.write(secrets, id: environment.id, label: "Viam Provisioner environment: \(environment.name)") }
        let flagged = environment.flagged(by: try secrets ?? self.secrets(id: environment.id))
        var environments = try read().filter { $0.id != environment.id }
        environments.append(flagged)
        try write(environments)
    }

    public func remove(id: UUID) throws {
        try write(try read().filter { $0.id != id })
        try vault.delete(id: id)
    }

    private func read() throws -> [Environment] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            return try JSONDecoder().decode([Environment].self, from: Data(contentsOf: file))
        } catch {
            throw EnvironmentStoreError.unreadable(path: file.path, reason: String(describing: error))
        }
    }

    private func write(_ environments: [Environment]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(environments.sortedByName()).write(to: file, options: .atomic)
        } catch {
            throw EnvironmentStoreError.unwritable(path: file.path, reason: error.localizedDescription)
        }
    }
}

/// Generic-password items under one service, keyed by environment ID, each
/// holding the secrets as JSON.
public struct KeychainSecretsVault: EnvironmentSecretsVault {
    public let service: String

    public init(service: String = "com.bringingfire.viam-provisioner.environment-secrets") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    public func read(id: UUID) throws -> EnvironmentSecrets? {
        var query = query(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw EnvironmentStoreError.keychain(status) }
        return try JSONDecoder().decode(EnvironmentSecrets.self, from: data)
    }

    public func write(_ secrets: EnvironmentSecrets, id: UUID, label: String) throws {
        let data = try JSONEncoder().encode(secrets)
        var status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EnvironmentStoreError.keychain(status) }
    }

    public func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EnvironmentStoreError.keychain(status) }
    }
}
