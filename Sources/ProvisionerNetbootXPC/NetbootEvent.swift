import Foundation

/// A PXE or TFTP event the netboot daemon sends its peers. MACs are lowercase and colon-separated.
public enum NetbootEvent: Codable, Hashable, Sendable {
    /// The netboot daemon answered a PXE discover with a boot offer: a boot from this MAC.
    case offered(mac: String, architecture: UInt16, uuid: String?)
    /// A client read a file from the TFTP root to its end. `mac` is nil when the netboot daemon saw no
    /// DHCP request from the client's address.
    case fileSent(filename: String, clientAddress: String, mac: String?, bytes: Int)

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(encoded data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
