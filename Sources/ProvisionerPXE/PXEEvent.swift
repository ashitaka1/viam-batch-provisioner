import NIOCore

/// What a `PXEServer` did for a client.
public enum PXEEvent: Hashable, Sendable {
    /// The server answered a PXE discover with a boot offer.
    case offered(PXEClient)
    /// The server built an offer for a PXE discover, but the socket refused to send it.
    case offerFailed(PXEOfferFailure)
    /// A TFTP read finished: the client acknowledged every block.
    case fileSent(TFTPDelivery)
}

/// An offer whose write failed, with what the server knows about it.
public struct PXEOfferFailure: Hashable, Sendable {
    public let mac: MACAddress
    public let destination: SocketAddress
    /// BSD name of the serving interface.
    public let interface: String
    /// The write's error, as the socket reported it.
    public let error: String

    public init(mac: MACAddress, destination: SocketAddress, interface: String, error: String) {
        self.mac = mac
        self.destination = destination
        self.interface = interface
        self.error = error
    }
}

/// A file a client read over TFTP.
public struct TFTPDelivery: Hashable, Sendable {
    /// The requested name, leading slashes removed.
    public let filename: String
    /// The client's IPv4 address, dotted quad.
    public let clientAddress: String
    /// The client's MAC, when the server saw a DHCP request from it for `clientAddress`.
    public let mac: MACAddress?
    public let bytes: Int

    public init(filename: String, clientAddress: String, mac: MACAddress?, bytes: Int) {
        self.filename = filename
        self.clientAddress = clientAddress
        self.mac = mac
        self.bytes = bytes
    }
}
