public import Foundation
package import ProvisionerAPI

public enum ServiceState: String, Sendable, Equatable {
    case up, down, unknown
}

public struct ServerStatus: Sendable, Equatable {
    public struct QueueCounts: Sendable, Equatable {
        public var queued, flashed, assigned, installing, installed, failed, total: Int
    }

    public struct Services: Sendable, Equatable {
        public var http, dnsmasq, watcher: ServiceState

        public init(http: ServiceState, dnsmasq: ServiceState, watcher: ServiceState) {
            self.http = http
            self.dnsmasq = dnsmasq
            self.watcher = watcher
        }
    }

    public var apiVersion: String
    public var serverName: String
    public var time: Date
    /// host:port of the HTTP file server, when the server can determine it.
    public var address: String?
    public var queue: QueueCounts?
    public var services: Services
    public var lastEventID: Int

    init(_ wire: Components.Schemas.ServerStatus) {
        apiVersion = wire.apiVersion.rawValue
        serverName = wire.serverName
        time = wire.time
        address = wire.address
        queue = wire.queue.map {
            QueueCounts(queued: $0.queued, flashed: $0.flashed, assigned: $0.assigned, installing: $0.installing,
                        installed: $0.installed, failed: $0.failed, total: $0.total)
        }
        services = Services(http: .init(rawValue: wire.services.http.rawValue)!,
                            dnsmasq: .init(rawValue: wire.services.dnsmasq.rawValue)!,
                            watcher: .init(rawValue: wire.services.watcher.rawValue)!)
        lastEventID = wire.lastEventId
    }
}
