/// What a `PXEServer` did for a client.
public enum PXEEvent: Hashable, Sendable {
    /// The server answered a PXE discover with a boot offer.
    case offered(PXEClient)
    /// A TFTP read finished: the client acknowledged every block.
    case fileSent(TFTPDelivery)
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
