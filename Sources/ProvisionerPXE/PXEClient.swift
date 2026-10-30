/// A PXE client the server answered.
public struct PXEClient: Hashable, Sendable {
    public let mac: MACAddress
    /// Client system architecture, RFC 4578 option 93.
    public let architecture: UInt16
    /// The 16-byte machine identifier from option 97, when the client sent one.
    public let uuid: [UInt8]?

    public init(mac: MACAddress, architecture: UInt16, uuid: [UInt8]?) {
        self.mac = mac
        self.architecture = architecture
        self.uuid = uuid
    }
}
