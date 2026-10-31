public import Foundation
import Security

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items under one service, keyed by org ID, each holding the
/// credential as JSON.
public struct KeychainOrgCredentialStore: OrgCredentialStore {
    public let service: String

    public init(service: String = "com.bringingfire.viam-provisioner.org-keys") {
        self.service = service
    }

    private func query(orgID: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let orgID { query[kSecAttrAccount as String] = orgID }
        return query
    }

    public func all() throws -> [OrgCredential] {
        // The file-based keychain returns data for one item per query, so list the
        // accounts first and read each item's data on its own.
        var list = query()
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        list[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let accounts = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        return try accounts.compactMap(read).sorted { $0.orgName < $1.orgName }
    }

    private func read(orgID: String) throws -> OrgCredential? {
        var query = query(orgID: orgID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(OrgCredential.self, from: data)
    }

    public func save(_ credential: OrgCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(orgID: credential.orgID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(orgID: credential.orgID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Viam Provisioner: \(credential.orgName)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(orgID: String) throws {
        let status = SecItemDelete(query(orgID: orgID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
