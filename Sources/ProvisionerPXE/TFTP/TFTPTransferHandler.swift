#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import NIOCore

/// Runs one `TFTPTransfer` on its own socket, reading each block from the file as it is sent.
/// Owns the file descriptor and closes it with the channel.
final class TFTPTransferHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private var transfer: TFTPTransfer
    private let negotiation: TFTPNegotiation
    private var descriptor: CInt
    private let client: SocketAddress
    private let timeout: TimeAmount
    private let completed: () -> Void
    private var timer: Scheduled<Void>?

    /// `completed` runs once the client has acknowledged the last block.
    init(
        transfer: TFTPTransfer, negotiation: TFTPNegotiation, descriptor: CInt, client: SocketAddress,
        timeout: TimeAmount, completed: @escaping () -> Void
    ) {
        self.transfer = transfer
        self.negotiation = negotiation
        self.descriptor = descriptor
        self.client = client
        self.timeout = timeout
        self.completed = completed
    }

    func channelActive(context: ChannelHandlerContext) {
        perform(transfer.start(), context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        closeFile()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.remoteAddress == client else {
            let error = TFTPPacket.error(code: TFTPErrorCode.unknownTID.rawValue, message: "Unknown transfer ID")
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: error.encoded())), promise: nil)
            return
        }
        switch TFTPPacket(buffer: envelope.data) {
        case let .ack(block):
            perform(transfer.received(ack: block), context: context)
        case .error:
            perform(transfer.receivedError(), context: context)
        default:
            return
        }
    }

    private func perform(_ action: TFTPTransfer.Action, context: ChannelHandlerContext) {
        switch action {
        case .sendOptionAck:
            send(.optionAck(negotiation.acknowledged), context: context)
            armTimer(context: context)
        case let .sendBlock(number, offset, length):
            var buffer = context.channel.allocator.buffer(capacity: length + 4)
            buffer.writeInteger(UInt16(3))
            buffer.writeInteger(number)
            let read = buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: length) { pointer in
                max(0, pread(descriptor, pointer.baseAddress, length, off_t(offset)))
            }
            guard read == length else {
                send(.error(code: TFTPErrorCode.notDefined.rawValue, message: "Read error"), context: context)
                finish(context: context)
                return
            }
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: client, data: buffer)), promise: nil)
            armTimer(context: context)
        case .finished:
            completed()
            finish(context: context)
        case .failed:
            finish(context: context)
        case .none:
            return
        }
    }

    private func send(_ packet: TFTPPacket, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: client, data: packet.encoded())), promise: nil)
    }

    private func armTimer(context: ChannelHandlerContext) {
        timer?.cancel()
        let context = NIOLoopBound(context, eventLoop: context.eventLoop)
        let handler = NIOLoopBound(self, eventLoop: context.value.eventLoop)
        timer = context.value.eventLoop.scheduleTask(in: timeout) {
            handler.value.perform(handler.value.transfer.timedOut(), context: context.value)
        }
    }

    private func finish(context: ChannelHandlerContext) {
        timer?.cancel()
        closeFile()
        context.close(promise: nil)
    }

    private func closeFile() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}
