import NIOCore

/// Answers PXE requests on one DHCP socket. Offers go to `offerDestination` (the broadcast
/// address in production, since the client has no IP yet); ACKs on 4011 go back to the sender.
final class DHCPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let listener: DHCPListener
    private let responder: ProxyDHCPResponder
    private let offerDestination: SocketAddress
    private let leases: LeaseTable
    private let report: @Sendable (PXEClient) -> Void

    init(
        listener: DHCPListener,
        responder: ProxyDHCPResponder,
        offerDestination: SocketAddress,
        leases: LeaseTable,
        report: @escaping @Sendable (PXEClient) -> Void
    ) {
        self.listener = listener
        self.responder = responder
        self.offerDestination = offerDestination
        self.leases = leases
        self.report = report
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let request = DHCPPacket(buffer: envelope.data) else { return }
        if let lease = responder.lease(in: request) {
            leases.record(lease.mac, at: lease.address)
        }
        guard let (reply, client) = responder.reply(to: request, on: listener) else { return }

        let destination = listener == .dhcp ? offerDestination : envelope.remoteAddress
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: destination, data: reply.encoded())), promise: nil)
        if let client {
            report(client)
        }
    }
}
