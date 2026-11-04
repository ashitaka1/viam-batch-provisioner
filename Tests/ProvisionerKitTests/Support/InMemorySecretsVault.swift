import Foundation
import os
import ProvisionerKit

/// Secrets in memory. While `failing`, every call throws, as a locked or
/// denied Keychain does.
final class InMemorySecretsVault: EnvironmentSecretsVault {
    struct Failure: Error {}
    private let items = OSAllocatedUnfairLock<[UUID: EnvironmentSecrets]>(initialState: [:])
    private let failure = OSAllocatedUnfairLock(initialState: false)

    var failing: Bool {
        get { failure.withLock { $0 } }
        set { failure.withLock { $0 = newValue } }
    }

    func read(id: UUID) throws -> EnvironmentSecrets? {
        if failing { throw Failure() }
        return items.withLock { $0[id] }
    }

    func write(_ secrets: EnvironmentSecrets, id: UUID, label: String) throws {
        if failing { throw Failure() }
        items.withLock { $0[id] = secrets }
    }

    func delete(id: UUID) throws {
        if failing { throw Failure() }
        _ = items.withLock { $0.removeValue(forKey: id) }
    }
}
