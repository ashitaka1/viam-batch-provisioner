import Darwin
import NIOCore
import NIOPosix

/// Accepts read requests on the TFTP port and hands each to a transfer on its own socket,
/// whose port is the server's transfer ID (RFC 1350 section 4).
final class TFTPListenerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let root: TFTPRoot
    private let host: String
    private let defaultTimeout: TimeAmount

    init(root: TFTPRoot, host: String, defaultTimeout: TimeAmount) {
        self.root = root
        self.host = host
        self.defaultTimeout = defaultTimeout
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

    private func startTransfer(filename: String, options: [TFTPOption], client: SocketAddress, context: ChannelHandlerContext) {
        guard let url = root.resolve(filename) else {
            reply(.error(code: TFTPErrorCode.fileNotFound.rawValue, message: "File not found"), to: client, context: context)
            return
        }
        let descriptor = open(url.path, O_RDONLY)
        var status = stat()
        guard descriptor >= 0, fstat(descriptor, &status) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            reply(.error(code: TFTPErrorCode.accessViolation.rawValue, message: "Cannot read file"), to: client, context: context)
            return
        }

        let negotiation = TFTPNegotiation(requested: options, fileSize: Int(status.st_size))
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
            .whenFailure { _ in close(descriptor) }
    }

    private func reply(_ packet: TFTPPacket, to address: SocketAddress, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: address, data: packet.encoded())), promise: nil)
    }
}
