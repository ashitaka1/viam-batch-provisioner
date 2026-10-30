public import Foundation
import Network

public struct DiscoveredServer: Sendable, Hashable {
    /// The Bonjour service name, or `host:port` for a manual address.
    public var name: String
    public var baseURL: URL

    public init(name: String, baseURL: URL) {
        self.name = name
        self.baseURL = baseURL
    }

    public static func manual(host: String, port: Int) -> DiscoveredServer {
        DiscoveredServer(name: "\(host):\(port)", baseURL: ServerBrowser.baseURL(host: host, port: port))
    }
}

/// Finds provisioning servers advertised as `_viam-provisioner._tcp` with TXT `api=v1`.
public final class ServerBrowser: Sendable {
    static let serviceType = "_viam-provisioner._tcp"

    public init() {}

    /// The servers currently visible, re-sent in full on every change. Browsing
    /// stops when the consumer stops iterating.
    public func servers() -> AsyncStream<[DiscoveredServer]> {
        AsyncStream { continuation in
            let session = BrowseSession(continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    static func isProvisioner(txt: [String: String]) -> Bool {
        txt["api"] == "v1"
    }

    static func baseURL(host: String, port: Int) -> URL {
        var host = host
        if let scope = host.firstIndex(of: "%") { host = String(host[..<scope]) }
        if host.contains(":") { host = "[\(host)]" }
        return URL(string: "http://\(host):\(port)/")!
    }
}

/// One browse. All state is confined to `queue`.
private final class BrowseSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProvisionerKit.ServerBrowser")
    private let continuation: AsyncStream<[DiscoveredServer]>.Continuation
    private let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: ServerBrowser.serviceType, domain: nil), using: .tcp)
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: DiscoveredServer] = [:]

    init(continuation: AsyncStream<[DiscoveredServer]>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            browser.cancel()
            resolving.values.forEach { $0.cancel() }
            resolving.removeAll()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let wanted = Set(results.filter { result in
            guard case .bonjour(let txt) = result.metadata else { return false }
            return ServerBrowser.isProvisioner(txt: txt.dictionary)
        }.map(\.endpoint))

        for endpoint in resolving.keys where !wanted.contains(endpoint) {
            resolving.removeValue(forKey: endpoint)?.cancel()
        }
        let before = found.count
        found = found.filter { wanted.contains($0.key) }
        for endpoint in wanted where found[endpoint] == nil && resolving[endpoint] == nil {
            resolve(endpoint)
        }
        if found.count != before { publish() }
    }

    /// Connects to the service to learn its address, then disconnects.
    private func resolve(_ endpoint: NWEndpoint) {
        guard case .service(let name, _, _, _) = endpoint else { return }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    found[endpoint] = DiscoveredServer(
                        name: name, baseURL: ServerBrowser.baseURL(host: "\(host)", port: Int(port.rawValue)))
                    publish()
                }
                fallthrough
            case .failed, .waiting:
                connection.cancel()
                resolving.removeValue(forKey: endpoint)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        continuation.yield(found.values.sorted { $0.name < $1.name })
    }
}
