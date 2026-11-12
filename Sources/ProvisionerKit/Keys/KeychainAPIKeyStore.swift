public import Foundation
import Security

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items under one service, the account being the key ID and
/// the data the key as JSON.
public struct KeychainAPIKeyStore: APIKeyStore {
    public let service: String

    public init(service: String = "com.bringingfire.viam-provisioner.api-keys") {
        self.service = service
    }

    private func query(keyID: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let keyID { query[kSecAttrAccount as String] = keyID }
        return query
    }

    public func all() throws -> APIKeyListing {
        // The file-based keychain returns data for one item per query, so list the
        // accounts first and read each item's data on its own.
        var list = query()
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        list[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return APIKeyListing(keys: [], unreadable: []) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let accounts = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        // An item that can't be read is reported as unreadable, as one that can't be decoded is.
        return Self.decode(accounts.compactMap { account in
            do {
                return try read(keyID: account).map { (account, $0) }
            } catch {
                return (account, Data())
            }
        })
    }

    /// Keys from items' data. An item that doesn't decode is reported by its
    /// account and the rest still load.
    public static func decode(_ items: [(account: String, data: Data)]) -> APIKeyListing {
        var keys: [ViamAPIKey] = []
        var unreadable: [String] = []
        for item in items {
            if let key = try? JSONDecoder().decode(ViamAPIKey.self, from: item.data) {
                keys.append(key)
            } else {
                unreadable.append(item.account)
            }
        }
        return APIKeyListing(keys: keys.sortedByLabel(), unreadable: unreadable.sorted())
    }

    private func read(keyID: String) throws -> Data? {
        var query = query(keyID: keyID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func save(_ key: ViamAPIKey) throws {
        let data = try JSONEncoder().encode(key)
        let label = "Viam Provisioner: \(key.scope.label)"
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(query(keyID: key.keyID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(keyID: key.keyID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(keyID: String) throws {
        let status = SecItemDelete(query(keyID: keyID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
