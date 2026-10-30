import Darwin
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
        var nextID = 0
        var closed = false
    }

    private let root: TFTPRoot
    private let host: String
    private let defaultTimeout: TimeAmount
    private let maxBlockSize: Int
    private let maxTransfers: Int
    private let registry = NIOLockedValueBox(Registry())

    init(root: TFTPRoot, host: String, defaultTimeout: TimeAmount, mtu: Int, maxTransfers: Int) {
        self.root = root
        self.host = host
        self.defaultTimeout = defaultTimeout
        // IPv4 (20) and UDP (8) headers plus the 4-byte DATA header.
        maxBlockSize = min(mtu - 32, Self.largestSendableBlock)
        self.maxTransfers = maxTransfers
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

    /// Ends every transfer and refuses new ones.
    func closeTransfers() {
        let channels = registry.withLockedValue { registry in
            registry.closed = true
            defer { registry.transfers = [:] }
            return registry.transfers.values.compactMap(\.channel)
        }
        for channel in channels {
            channel.close(promise: nil)
        }
    }

    private func startTransfer(filename: String, options: [TFTPOption], client: SocketAddress, context: ChannelHandlerContext) {
        guard let url = root.resolve(filename) else {
            reply(.error(code: TFTPErrorCode.fileNotFound.rawValue, message: "File not found"), to: client, context: context)
            return
        }
        guard let id = reserve(for: client) else {
            reply(.error(code: TFTPErrorCode.notDefined.rawValue, message: "Server busy"), to: client, context: context)
            return
        }
        let descriptor = open(url.path, O_RDONLY)
        var status = stat()
        guard descriptor >= 0, fstat(descriptor, &status) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            release(client, id: id)
            reply(.error(code: TFTPErrorCode.accessViolation.rawValue, message: "Cannot read file"), to: client, context: context)
            return
        }

        let negotiation = TFTPNegotiation(requested: options, fileSize: Int(status.st_size), maxBlockSize: maxBlockSize)
        let timeout = negotiation.timeoutSeconds.map { TimeAmount.seconds(Int64($0)) } ?? defaultTimeout
        let transfer = TFTPTransfer(fileSize: Int(status.st_size), negotiation: negotiation)

        DatagramBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TFTPTransferHandler(
                        transfer: transfer, negotiation: negotiation, descriptor: descriptor,
                        client: client, timeout: timeout
                    ))
                }
            }
            .bind(host: host, port: 0)
            .whenComplete { [self] result in
                switch result {
                case let .success(channel):
                    register(channel, for: client, id: id)
                case .failure:
                    close(descriptor)
                    release(client, id: id)
                }
            }
    }

    /// Claims the client's slot, ending any transfer it already has. nil when the server is full or stopped.
    private func reserve(for client: SocketAddress) -> Int? {
        let (id, replaced) = registry.withLockedValue { registry -> (Int?, (any Channel)?) in
            guard !registry.closed else { return (nil, nil) }
            let existing = registry.transfers[client]
            guard existing != nil || registry.transfers.count < maxTransfers else { return (nil, nil) }
            registry.nextID += 1
            registry.transfers[client] = Transfer(id: registry.nextID, channel: nil)
            return (registry.nextID, existing?.channel)
        }
        replaced?.close(promise: nil)
        return id
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
