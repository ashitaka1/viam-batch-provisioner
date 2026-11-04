import Foundation
import os
import ProvisionerKit

final class InMemorySecretsVault: EnvironmentSecretsVault {
    private let items = OSAllocatedUnfairLock<[UUID: EnvironmentSecrets]>(initialState: [:])

    func read(id: UUID) throws -> EnvironmentSecrets? { items.withLock { $0[id] } }
    func write(_ secrets: EnvironmentSecrets, id: UUID, label: String) throws { items.withLock { $0[id] = secrets } }
    func delete(id: UUID) throws { _ = items.withLock { $0.removeValue(forKey: id) } }
}
