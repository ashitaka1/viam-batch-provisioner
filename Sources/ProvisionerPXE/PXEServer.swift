import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

public struct PXEConfiguration: Sendable {
    /// BSD name of the serving interface, such as `en0`.
    public var interface: String
    public var tftpRoot: URL
    public var bootFilename = "grubx64.efi"
    public var dhcpPort = 67
    public var pxePort = 4011
    public var tftpPort = 69
    /// Where offers go. nil sends them to 255.255.255.255:68.
    public var offerDestination: SocketAddress?
    /// Retransmit interval for a TFTP transfer whose client did not negotiate one.
    public var tftpTimeout: TimeAmount = .seconds(1)
    /// Concurrent TFTP transfers; a read request beyond this gets an error.
    public var maxTransfers = 64
    /// Reports `clients` holds for a reader that falls behind; older ones are dropped first. At least 1.
    public var clientBufferLimit = 256

    public init(interface: String, tftpRoot: URL) {
        self.interface = interface
        self.tftpRoot = tftpRoot
    }
}

/// Proxy DHCP and TFTP for PXE clients on one interface.
///
/// A server starts once and stops once: `start()` throws on a server that is starting,
/// running or stopped. A `start()` that throws for any other reason may be retried.
public final class PXEServer: Sendable {
    /// One report per PXE discover, firmware retries included. Finishes on `stop()`.
    /// It holds the newest `clientBufferLimit` reports that no one has read.
    public let clients: AsyncStream<PXEClient>

    private enum State {
        case idle
        /// Completes once the in-flight `start()` has finished, including closing its sockets.
        case starting(EventLoopFuture<Void>)
        case running(channels: [any Channel], tftpListener: TFTPListenerHandler)
        case stopped
    }

    private let configuration: PXEConfiguration
    private let group: any EventLoopGroup
    private let clientsContinuation: AsyncStream<PXEClient>.Continuation
    private let state = NIOLockedValueBox(State.idle)

    public init(configuration: PXEConfiguration, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        precondition(configuration.clientBufferLimit >= 1, "clientBufferLimit must be at least 1")
        self.configuration = configuration
        self.group = group
        (clients, clientsContinuation) = AsyncStream.makeStream(
            of: PXEClient.self, bufferingPolicy: .bufferingNewest(configuration.clientBufferLimit))
    }

    /// The ports bound by `start()`, which differ from the configuration when it asks for port 0.
    public var boundPorts: (dhcp: Int, pxe: Int, tftp: Int)? {
        let ports = listeningChannels.compactMap { $0.localAddress?.port }
        guard ports.count == 3 else { return nil }
        return (ports[0], ports[1], ports[2])
    }

    public func start() async throws {
        let started = try state.withLockedValue { state in
            switch state {
            case .idle:
                let started = group.next().makePromise(of: Void.self)
                state = .starting(started.futureResult)
                return started
            case .starting, .running: throw PXEServerError.alreadyStarted
            case .stopped: throw PXEServerError.stopped
            }
        }
        defer { started.succeed() }
        do {
            try await bind()
        } catch {
            state.withLockedValue { state in
                if case .starting = state { state = .idle }
            }
            throw error
        }
    }

    /// Binds the three listeners, closing those already bound when a later one fails.
    private func bind() async throws {
        let interface = try NetworkInterface.lookup(configuration.interface)
        let host = Self.dottedQuad(interface.address)
        let responder = ProxyDHCPResponder(serverAddress: interface.address, bootFilename: configuration.bootFilename)
        let offerDestination = try configuration.offerDestination ?? SocketAddress(ipAddress: "255.255.255.255", port: 68)
        let report: @Sendable (PXEClient) -> Void = { [clientsContinuation] in clientsContinuation.yield($0) }

        var bound: [any Channel] = []
        let listener = TFTPListenerHandler(
            root: TFTPRoot(configuration.tftpRoot), host: host, defaultTimeout: configuration.tftpTimeout,
            mtu: interface.mtu, maxTransfers: configuration.maxTransfers
        )
        do {
            for (listener, port) in [(DHCPListener.dhcp, configuration.dhcpPort), (.pxe, configuration.pxePort)] {
                let handler = DHCPHandler(listener: listener, responder: responder, offerDestination: offerDestination, report: report)
                bound.append(try await bindDHCP(port: port, interfaceIndex: interface.index, handler: handler))
            }
            bound.append(try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(listener) }
                }
                .bind(host: host, port: configuration.tftpPort)
                .get())
        } catch {
            await Self.close(bound, listener)
            throw error
        }
        let running = state.withLockedValue { state in
            guard case .starting = state else { return false }
            state = .running(channels: bound, tftpListener: listener)
            return true
        }
        if !running {
            // stop() ran while this was binding.
            await Self.close(bound, listener)
            throw PXEServerError.stopped
        }
    }

    /// The DHCP, PXE and TFTP listening channels, in that order; empty unless running.
    var listeningChannels: [any Channel] {
        state.withLockedValue { state in
            guard case let .running(channels, _) = state else { return [] }
            return channels
        }
    }

    /// Releases the ports, ends transfers and finishes `clients`. The server cannot start again.
    /// During a `start()`, waits for that start to close what it bound.
    public func stop() async {
        let previous = state.withLockedValue { state in
            defer { state = .stopped }
            return state
        }
        switch previous {
        case let .running(channels, listener): await Self.close(channels, listener)
        case let .starting(started): try? await started.get()
        case .idle, .stopped: break
        }
        clientsContinuation.finish()
    }

    private static func close(_ channels: [any Channel], _ listener: TFTPListenerHandler) async {
        for channel in channels {
            try? await channel.close()
        }
        listener.closeTransfers()
    }

    /// Binds 0.0.0.0 restricted to the interface: on macOS a socket bound to a unicast
    /// address never receives the 255.255.255.255 discovers PXE firmware sends.
    private func bindDHCP(port: Int, interfaceIndex: UInt32, handler: DHCPHandler) async throws -> any Channel {
        try await DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.so_broadcast), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_IP), IP_BOUND_IF), value: SocketOptionValue(interfaceIndex))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
            }
            .bind(host: "0.0.0.0", port: port)
            .get()
    }

    private static func dottedQuad(_ address: UInt32) -> String {
        [24, 16, 8, 0].map { String((address >> $0) & 0xFF) }.joined(separator: ".")
    }
}
