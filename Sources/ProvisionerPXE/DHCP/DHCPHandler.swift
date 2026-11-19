import NIOCore

/// Answers PXE requests on one DHCP socket. Offers go to `offerDestination` (the broadcast
/// address in production, since the client has no IP yet); ACKs on 4011 go back to the sender.
/// An offer is reported once its write succeeds, and reported as failed when the write fails.
final class DHCPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let listener: DHCPListener
    private let responder: ProxyDHCPResponder
    private let offerDestination: SocketAddress
    private let interface: String
    private let leases: LeaseTable
    private let report: @Sendable (PXEEvent) -> Void

    init(
        listener: DHCPListener,
        responder: ProxyDHCPResponder,
        offerDestination: SocketAddress,
        interface: String,
        leases: LeaseTable,
        report: @escaping @Sendable (PXEEvent) -> Void
    ) {
        self.listener = listener
        self.responder = responder
        self.offerDestination = offerDestination
        self.interface = interface
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
        let outbound = wrapOutboundOut(AddressedEnvelope(remoteAddress: destination, data: reply.encoded()))
        guard let client else {
            context.writeAndFlush(outbound, promise: nil)
            return
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        let (report, interface) = (report, interface)
        promise.futureResult.whenComplete { result in
            switch result {
            case .success:
                report(.offered(client))
            case let .failure(error):
                report(.offerFailed(PXEOfferFailure(
                    mac: client.mac, destination: destination, interface: interface, error: "\(error)")))
            }
        }
        context.writeAndFlush(outbound, promise: promise)
    }
}
