public import Foundation
public import Observation

/// The provisioning server this Mac uses: one advertised over Bonjour or typed
/// in, remembered across launches.
@MainActor @Observable
public final class ServerSelection {
    public struct InvalidAddress: Error, LocalizedError {
        public var errorDescription: String? { "Enter a hostname or IP address and a port from 1 to 65535." }
    }

    private static let nameKey = "server.name"
    private static let urlKey = "server.url"

    public private(set) var selected: DiscoveredServer?
    /// The servers Bonjour sees now.
    public private(set) var discovered: [DiscoveredServer] = []
    public private(set) var browseError: String?

    private let defaults: UserDefaults
    private let browseServers: @Sendable () -> AsyncThrowingStream<[DiscoveredServer], any Error>

    public init(defaults: UserDefaults = .standard,
                browse: @escaping @Sendable () -> AsyncThrowingStream<[DiscoveredServer], any Error> = { ServerBrowser().servers() }) {
        self.defaults = defaults
        browseServers = browse
        if let name = defaults.string(forKey: Self.nameKey), let url = defaults.url(forKey: Self.urlKey) {
            selected = DiscoveredServer(name: name, baseURL: url)
        }
    }

    public func select(_ server: DiscoveredServer) {
        selected = server
        defaults.set(server.name, forKey: Self.nameKey)
        defaults.set(server.baseURL, forKey: Self.urlKey)
    }

    public func connect(host: String, port: Int) throws(InvalidAddress) {
        guard let server = DiscoveredServer.manual(host: host, port: port) else { throw InvalidAddress() }
        select(server)
    }

    /// Browses until cancelled or browsing fails.
    public func browse() async {
        browseError = nil
        do {
            for try await servers in browseServers() {
                discovered = servers
                if let selected, let moved = servers.first(where: { $0.name == selected.name }), moved != selected {
                    select(moved)
                }
            }
        } catch {
            browseError = "Couldn't look for servers on the network: \(error.localizedDescription)"
        }
    }
}
