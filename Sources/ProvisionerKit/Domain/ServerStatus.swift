public import Foundation
internal import ProvisionerAPI

public enum ServiceState: String, Sendable, Equatable {
    case up, down, unknown
}

public struct ServerStatus: Sendable, Equatable {
    public struct QueueCounts: Sendable, Equatable {
        public var queued, flashed, assigned, installing, installed, failed, total: Int
    }

    public struct Services: Sendable, Equatable {
        public var http: ServiceState
        /// Reported by the Python server only.
        public var dnsmasq, watcher: ServiceState?
        /// Reported by the Swift server only.
        public var helper: ServiceState?

        public init(http: ServiceState, dnsmasq: ServiceState? = nil, watcher: ServiceState? = nil,
                    helper: ServiceState? = nil) {
            self.http = http
            self.dnsmasq = dnsmasq
            self.watcher = watcher
            self.helper = helper
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
                            dnsmasq: wire.services.dnsmasq.map { .init(rawValue: $0.rawValue)! },
                            watcher: wire.services.watcher.map { .init(rawValue: $0.rawValue)! },
                            helper: wire.services.helper.map { .init(rawValue: $0.rawValue)! })
        lastEventID = wire.lastEventId
    }
}
