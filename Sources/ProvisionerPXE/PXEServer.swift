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

    public init(interface: String, tftpRoot: URL) {
        self.interface = interface
        self.tftpRoot = tftpRoot
    }
}

/// Proxy DHCP and TFTP for PXE clients on one interface.
public final class PXEServer: Sendable {
    public let clients: AsyncStream<PXEClient>

    private let configuration: PXEConfiguration
    private let group: any EventLoopGroup
    private let clientsContinuation: AsyncStream<PXEClient>.Continuation
    private let channels = NIOLockedValueBox<[any Channel]>([])

    public init(configuration: PXEConfiguration, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.configuration = configuration
        self.group = group
        (clients, clientsContinuation) = AsyncStream.makeStream(of: PXEClient.self)
    }

    /// The ports bound by `start()`, which differ from the configuration when it asks for port 0.
    public var boundPorts: (dhcp: Int, pxe: Int, tftp: Int)? {
        channels.withLockedValue { channels in
            guard channels.count == 3 else { return nil }
            let ports = channels.compactMap { $0.localAddress?.port }
            guard ports.count == 3 else { return nil }
            return (ports[0], ports[1], ports[2])
        }
    }

    public func start() async throws {
        let interface = try NetworkInterface.lookup(configuration.interface)
        let host = Self.dottedQuad(interface.address)
        let responder = ProxyDHCPResponder(serverAddress: interface.address, bootFilename: configuration.bootFilename)
        let offerDestination = try configuration.offerDestination ?? SocketAddress(ipAddress: "255.255.255.255", port: 68)
        let report: @Sendable (PXEClient) -> Void = { [clientsContinuation] in clientsContinuation.yield($0) }

        var bound: [any Channel] = []
        do {
            for (listener, port) in [(DHCPListener.dhcp, configuration.dhcpPort), (.pxe, configuration.pxePort)] {
                let handler = DHCPHandler(listener: listener, responder: responder, offerDestination: offerDestination, report: report)
                bound.append(try await bindDHCP(port: port, interfaceIndex: interface.index, handler: handler))
            }
            let listener = TFTPListenerHandler(root: TFTPRoot(configuration.tftpRoot), host: host, defaultTimeout: configuration.tftpTimeout)
            bound.append(try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(listener) }
                }
                .bind(host: host, port: configuration.tftpPort)
                .get())
        } catch {
            for channel in bound { try? await channel.close() }
            throw error
        }
        channels.withLockedValue { $0 = bound }
    }

    public func stop() async throws {
        let bound = channels.withLockedValue { channels in
            defer { channels = [] }
            return channels
        }
        for channel in bound {
            try await channel.close()
        }
        clientsContinuation.finish()
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
