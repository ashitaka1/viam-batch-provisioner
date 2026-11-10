import Foundation
import os
import ProvisionerNetbootXPC
import ProvisionerPXE

/// The netboot daemon's XPC listener delegate: accepts peers, hosts at most one `PXEServer`, and
/// sends every PXE event to every connected peer.
public final class NetbootService: NSObject, NSXPCListenerDelegate, Sendable {
    public typealias Configure = @Sendable (_ interface: String, _ bootFilename: String, _ root: URL) -> PXEConfiguration

    public static let standardConfiguration: Configure = { interface, bootFilename, root in
        var configuration = PXEConfiguration(interface: interface, tftpRoot: root)
        configuration.bootFilename = bootFilename
        return configuration
    }

    let files: TFTPRootFiles
    let host: PXEHost
    private let acceptPeer: @Sendable (NSXPCConnection) -> Bool
    private let peers = OSAllocatedUnfairLock(uncheckedState: [ObjectIdentifier: NSXPCConnection]())
    static let log = Logger(subsystem: ProvisionerNetbootXPC.machServiceName, category: "netboot")

    /// `acceptPeer` runs on each connection, after the listener's code signing requirement.
    public init(
        root: URL,
        acceptPeer: @escaping @Sendable (NSXPCConnection) -> Bool = { _ in true },
        configure: @escaping Configure = NetbootService.standardConfiguration
    ) {
        files = TFTPRootFiles(root: root)
        self.acceptPeer = acceptPeer
        let peers = peers
        host = PXEHost(root: root, configure: configure) { event in
            guard let data = try? NetbootEvent(event).encoded() else { return }
            for peer in peers.withLockUnchecked({ Array($0.values) }) {
                (peer.remoteObjectProxyWithErrorHandler { _ in } as? any ProvisionerNetbootEventsProtocol)?.netbootEvent(data)
            }
        }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard acceptPeer(connection) else {
            Self.log.error("refused peer \(connection.processIdentifier) running as uid \(connection.effectiveUserIdentifier)")
            return false
        }
        connection.exportedInterface = ProvisionerNetbootXPC.netbootInterface()
        connection.exportedObject = NetbootEndpoint(service: self)
        connection.remoteObjectInterface = ProvisionerNetbootXPC.eventsInterface()
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [peers] in
            _ = peers.withLockUnchecked { $0.removeValue(forKey: id) }
        }
        peers.withLockUnchecked { $0[id] = connection }
        Self.log.info("peer \(connection.processIdentifier) connected")
        connection.resume()
        return true
    }

    /// Stops serving and releases the ports.
    public func shutdown() async {
        await host.stop()
    }
}

extension NetbootEvent {
    init(_ event: PXEEvent) {
        switch event {
        case let .offered(client):
            self = .offered(
                mac: client.mac.description, architecture: client.architecture,
                uuid: client.uuid.map { $0.map { String(format: "%02x", $0) }.joined() })
        case let .fileSent(delivery):
            self = .fileSent(
                filename: delivery.filename, clientAddress: delivery.clientAddress,
                mac: delivery.mac?.description, bytes: delivery.bytes)
        }
    }
}

/// Runs one `PXEServer` at a time. Operations run in the order they arrive, each to completion.
actor PXEHost {
    private struct Serving {
        let interface: String
        let bootFilename: String
        let server: PXEServer
        let pump: Task<Void, Never>
    }

    private let root: URL
    private let configure: NetbootService.Configure
    private let send: @Sendable (PXEEvent) -> Void
    private var serving: Serving?
    private var tail: Task<Void, Never>?

    init(root: URL, configure: @escaping NetbootService.Configure, send: @escaping @Sendable (PXEEvent) -> Void) {
        self.root = root
        self.configure = configure
        self.send = send
    }

    var servingInterface: String? { serving?.interface }

    func serve(interface: String, bootFilename: String) async throws {
        try await serially {
            if let serving = await self.serving, serving.interface == interface, serving.bootFilename == bootFilename { return }
            await self.stopNow()
            let server = PXEServer(configuration: self.configure(interface, bootFilename, self.root))
            do {
                try await server.start()
            } catch {
                throw NetbootError.serveFailed("\(interface): \(error)")
            }
            let send = self.send
            let pump = Task {
                for await event in server.events { send(event) }
            }
            await self.setServing(Serving(interface: interface, bootFilename: bootFilename, server: server, pump: pump))
            NetbootService.log.info("serving on \(interface, privacy: .public) with \(bootFilename, privacy: .public)")
        }
    }

    func stop() async {
        try? await serially { await self.stopNow() }
    }

    private func setServing(_ serving: Serving) {
        self.serving = serving
    }

    private func stopNow() async {
        guard let serving else { return }
        self.serving = nil
        await serving.server.stop()
        await serving.pump.value
        NetbootService.log.info("stopped serving on \(serving.interface, privacy: .public)")
    }

    /// Runs `operation` after every operation queued before it has finished.
    private func serially(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Result<Void, any Error>, Never> {
            await previous?.value
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        tail = Task { _ = await task.value }
        try await task.value.get()
    }
}

/// The object a peer's calls land on.
final class NetbootEndpoint: NSObject, ProvisionerNetbootProtocol, Sendable {
    private let service: NetbootService

    init(service: NetbootService) {
        self.service = service
    }

    func serve(interface: String, bootFilename: String, reply: @escaping @Sendable (NSError?) -> Void) {
        Task {
            do {
                try await service.host.serve(interface: interface, bootFilename: bootFilename)
                reply(nil)
            } catch {
                NetbootService.log.error("serve failed: \(String(describing: error), privacy: .public)")
                reply(Self.nsError(error))
            }
        }
    }

    func stopServing(reply: @escaping @Sendable () -> Void) {
        Task {
            await service.host.stop()
            reply()
        }
    }

    func servingInterface(reply: @escaping @Sendable (String?) -> Void) {
        Task { reply(await service.host.servingInterface) }
    }

    func writeFile(_ path: String, contents: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try service.files.write(contents, to: path)
            reply(nil)
        } catch {
            reply(Self.nsError(error))
        }
    }

    func removeFile(_ path: String, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try service.files.remove(path)
            reply(nil)
        } catch {
            reply(Self.nsError(error))
        }
    }

    private static func nsError(_ error: any Error) -> NSError {
        (error as? NetbootError ?? .writeFailed("\(error)")).nsError
    }
}
