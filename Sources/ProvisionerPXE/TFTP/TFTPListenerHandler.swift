#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Accepts read requests on the TFTP port and hands each to a transfer on its own socket,
/// whose port is the server's transfer ID (RFC 1350 section 4). Holds one transfer per
/// client address, at most `maxTransfers` at once.
final class TFTPListenerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    /// macOS refuses UDP sends above `net.inet.udp.maxdgram` (9216 by default); less the 4-byte DATA header.
    static let largestSendableBlock = 9212

    private struct Transfer {
        let id: Int
        var channel: (any Channel)?
    }

    private struct Registry {
        var transfers: [SocketAddress: Transfer] = [:]
        /// Every transfer not yet ended, including those still binding or replaced: each
        /// future completes once the transfer's socket has closed or its bind has failed.
        var live: [Int: EventLoopFuture<Void>] = [:]
        var nextID = 0
        var closed = false
    }

    private let root: TFTPRoot
    private let host: String
    private let defaultTimeout: TimeAmount
    private let maxBlockSize: Int
    private let maxTransfers: Int
    private let leases: LeaseTable
    private let report: @Sendable (TFTPDelivery) -> Void
    private let registry = NIOLockedValueBox(Registry())

    init(
        root: TFTPRoot, host: String, defaultTimeout: TimeAmount, mtu: Int, maxTransfers: Int,
        leases: LeaseTable, report: @escaping @Sendable (TFTPDelivery) -> Void
    ) {
        self.root = root
        self.host = host
        self.defaultTimeout = defaultTimeout
        // IPv4 (20) and UDP (8) headers plus the 4-byte DATA header.
        maxBlockSize = min(mtu - 32, Self.largestSendableBlock)
        self.maxTransfers = maxTransfers
        self.leases = leases
        self.report = report
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        switch TFTPPacket(buffer: envelope.data) {
        case let .readRequest(filename, _, options):
            startTransfer(filename: filename, options: options, client: envelope.remoteAddress, context: context)
        case .writeRequest:
            reply(.error(code: TFTPErrorCode.illegalOperation.rawValue, message: "Read-only server"), to: envelope.remoteAddress, context: context)
        default:
            return
        }
    }

    /// Ends every transfer and refuses new ones. Returns once each transfer's socket has
    /// closed, including transfers still binding when this is called.
    func closeTransfers() async {
        let (channels, live) = registry.withLockedValue { registry in
            registry.closed = true
            defer { registry.transfers = [:] }
            return (registry.transfers.values.compactMap(\.channel), Array(registry.live.values))
        }
        for channel in channels {
            channel.close(promise: nil)
        }
        for ended in live {
            try? await ended.get()
        }
    }

    private func startTransfer(filename: String, options: [TFTPOption], client: SocketAddress, context: ChannelHandlerContext) {
        guard let url = root.resolve(filename) else {
            reply(.error(code: TFTPErrorCode.fileNotFound.rawValue, message: "File not found"), to: client, context: context)
            return
        }
        guard let (id, ended) = reserve(for: client, on: context.eventLoop) else {
            reply(.error(code: TFTPErrorCode.notDefined.rawValue, message: "Server busy"), to: client, context: context)
            return
        }
        // O_NONBLOCK and the S_IFREG check cover a file swapped for a FIFO after
        // resolve: opening a FIFO blocks the event loop until a writer appears.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        var status = stat()
        guard descriptor >= 0, fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            if descriptor >= 0 { close(descriptor) }
            release(client, id: id)
            ended.succeed(())
            reply(.error(code: TFTPErrorCode.accessViolation.rawValue, message: "Cannot read file"), to: client, context: context)
            return
        }

        let negotiation = TFTPNegotiation(requested: options, fileSize: Int(status.st_size), maxBlockSize: maxBlockSize)
        let timeout = negotiation.timeoutSeconds.map { TimeAmount.seconds(Int64($0)) } ?? defaultTimeout
        let transfer = TFTPTransfer(fileSize: Int(status.st_size), negotiation: negotiation)
        let delivery = delivery(of: filename, bytes: Int(status.st_size), to: client)

        DatagramBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TFTPTransferHandler(
                        transfer: transfer, negotiation: negotiation, descriptor: descriptor,
                        client: client, timeout: timeout,
                        completed: { [self] in report(delivery()) }
                    ))
                }
            }
            .bind(host: host, port: 0)
            .whenComplete { [self] result in
                switch result {
                case let .success(channel):
                    register(channel, for: client, id: id)
                    channel.closeFuture.whenComplete { _ in ended.succeed(()) }
                case .failure:
                    close(descriptor)
                    release(client, id: id)
                    ended.succeed(())
                }
            }
    }

    /// Builds the report when the transfer completes, so a DHCP request seen meanwhile still names the MAC.
    private func delivery(of filename: String, bytes: Int, to client: SocketAddress) -> @Sendable () -> TFTPDelivery {
        let name = String(filename.drop { $0 == "/" })
        let address: UInt32? = if case let .v4(v4) = client { UInt32(bigEndian: v4.address.sin_addr.s_addr) } else { nil }
        let clientAddress = client.ipAddress ?? "\(client)"
        return { [leases] in
            TFTPDelivery(filename: name, clientAddress: clientAddress, mac: address.flatMap(leases.mac(at:)), bytes: bytes)
        }
    }

    /// Claims the client's slot, ending any transfer it already has. nil when the server is full
    /// or stopped. The caller completes the promise when the transfer ends.
    private func reserve(for client: SocketAddress, on eventLoop: any EventLoop) -> (Int, EventLoopPromise<Void>)? {
        let ended = eventLoop.makePromise(of: Void.self)
        let (id, replaced) = registry.withLockedValue { registry -> (Int?, (any Channel)?) in
            guard !registry.closed else { return (nil, nil) }
            let existing = registry.transfers[client]
            guard existing != nil || registry.transfers.count < maxTransfers else { return (nil, nil) }
            registry.nextID += 1
            registry.transfers[client] = Transfer(id: registry.nextID, channel: nil)
            registry.live[registry.nextID] = ended.futureResult
            return (registry.nextID, existing?.channel)
        }
        replaced?.close(promise: nil)
        guard let id else {
            ended.succeed(())
            return nil
        }
        ended.futureResult.whenComplete { [registry] _ in
            registry.withLockedValue { _ = $0.live.removeValue(forKey: id) }
        }
        return (id, ended)
    }

    /// Records the bound channel, or closes it when a newer request or `closeTransfers` took the slot.
    private func register(_ channel: any Channel, for client: SocketAddress, id: Int) {
        let current = registry.withLockedValue { registry -> Bool in
            guard registry.transfers[client]?.id == id else { return false }
            registry.transfers[client]?.channel = channel
            return true
        }
        guard current else {
            channel.close(promise: nil)
            return
        }
        channel.closeFuture.whenComplete { [self] _ in release(client, id: id) }
    }

    private func release(_ client: SocketAddress, id: Int) {
        registry.withLockedValue { registry in
            if registry.transfers[client]?.id == id {
                registry.transfers[client] = nil
            }
        }
    }

    private func reply(_ packet: TFTPPacket, to address: SocketAddress, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: address, data: packet.encoded())), promise: nil)
    }
}
