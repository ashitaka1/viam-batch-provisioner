import Foundation

/// The XPC surface of `ProvisionerHelper`, the root launch daemon that hosts ProvisionerPXE.
/// Its peer, `ProvisionerServer`, tells it where to serve, writes the TFTP root, and
/// receives its PXE and TFTP events through `ProvisionerHelperEventsProtocol`.
public enum ProvisionerHelperXPC {
    public static let machServiceName = "com.bringingfire.viam-provisioner.helper"
    /// Code signing identifiers the helper accepts from a peer signed without a team.
    public static let peerIdentifiers = [
        "com.bringingfire.viam-provisioner.server",
        "com.bringingfire.viam-provisioner.helperctl",
    ]

    public static func helperInterface() -> NSXPCInterface {
        NSXPCInterface(with: (any ProvisionerHelperProtocol).self)
    }

    public static func eventsInterface() -> NSXPCInterface {
        NSXPCInterface(with: (any ProvisionerHelperEventsProtocol).self)
    }
}

/// Exported by the helper. Each reply carries nil on success, else an error in `HelperError.domain`.
@objc public protocol ProvisionerHelperProtocol {
    /// Serves proxy DHCP and TFTP on the interface, replacing any server on another interface or
    /// boot file. Serving outlives the connection that asked for it.
    func serve(interface: String, bootFilename: String, reply: @escaping @Sendable (NSError?) -> Void)
    func stopServing(reply: @escaping @Sendable () -> Void)
    /// The interface being served, nil when not serving. A peer receives events from its first call on.
    func servingInterface(reply: @escaping @Sendable (String?) -> Void)
    /// Writes a file at a relative path inside the TFTP root, creating its directories.
    func writeFile(_ path: String, contents: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Removes a file inside the TFTP root. A missing file is not an error.
    func removeFile(_ path: String, reply: @escaping @Sendable (NSError?) -> Void)
}

/// Exported by the helper's peer to receive events.
@objc public protocol ProvisionerHelperEventsProtocol {
    /// A JSON-encoded `HelperEvent`.
    func helperEvent(_ event: Data)
}
