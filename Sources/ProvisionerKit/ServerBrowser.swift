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

    /// A server the operator typed in. Nil when `host` isn't a hostname or IP
    /// address, or `port` isn't a TCP port.
    public static func manual(host: String, port: Int) -> DiscoveredServer? {
        guard let url = ServerBrowser.baseURL(host: host, port: port) else { return nil }
        return DiscoveredServer(name: "\(host.trimmingCharacters(in: .whitespaces)):\(port)", baseURL: url)
    }
}

/// Finds provisioning servers advertised as `_viam-provisioner._tcp` with TXT `api=v1`.
public final class ServerBrowser: Sendable {
    static let serviceType = "_viam-provisioner._tcp"

    public init() {}

    enum Outcome: Equatable {
        case publish
        case fail(NWError)
        case none
    }

    /// The servers currently visible, re-sent in full on every change, starting
    /// with the (possibly empty) list once browsing is up. Throws when browsing
    /// can't run, such as when Local Network access is denied. Browsing stops
    /// when the consumer stops iterating.
    public func servers() -> AsyncThrowingStream<[DiscoveredServer], any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = BrowseSession(continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    static func isProvisioner(txt: [String: String]) -> Bool {
        txt["api"] == "v1"
    }

    static func outcome(of state: NWBrowser.State) -> Outcome {
        switch state {
        case .ready: .publish
        case .failed(let error), .waiting(let error): .fail(error)
        default: .none
        }
    }

    static func baseURL(host: String, port: Int) -> URL? {
        var host = host.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let scope = host.firstIndex(of: "%") { host = String(host[..<scope]) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), (1...65535).contains(port)
        else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = "/"
        return components.url
    }
}

/// One browse. All state is confined to `queue`.
private final class BrowseSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProvisionerKit.ServerBrowser")
    private let continuation: AsyncThrowingStream<[DiscoveredServer], any Error>.Continuation
    private let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: ServerBrowser.serviceType, domain: nil), using: .tcp)
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: DiscoveredServer] = [:]

    init(continuation: AsyncThrowingStream<[DiscoveredServer], any Error>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch ServerBrowser.outcome(of: state) {
            case .publish: publish()
            case .fail(let error): continuation.finish(throwing: error)
            case .none: break
            }
        }
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
                    if let url = ServerBrowser.baseURL(host: "\(host)", port: Int(port.rawValue)) {
                        found[endpoint] = DiscoveredServer(name: name, baseURL: url)
                        publish()
                    }
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
