import NIOCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Restricts a socket to one interface, so a socket bound to 0.0.0.0 sends and receives
/// broadcasts there alone: `IP_BOUND_IF` on macOS, `SO_BINDTODEVICE` on Linux (decision 34).
enum InterfaceBinding {
    struct Unsupported: Error {}

    /// Call before the channel binds, as from a bootstrap's channel initializer.
    static func restrict(_ channel: any Channel, to interface: NetworkInterface) -> EventLoopFuture<Void> {
        guard let provider = channel as? any SocketOptionProvider else {
            return channel.eventLoop.makeFailedFuture(Unsupported())
        }
        #if canImport(Darwin)
        return provider.unsafeSetSocketOption(level: SocketOptionLevel(IPPROTO_IP), name: IP_BOUND_IF, value: CInt(interface.index))
        #else
        // The option value is the interface name, NUL-padded to IFNAMSIZ bytes.
        var name: (UInt64, UInt64) = (0, 0)
        withUnsafeMutableBytes(of: &name) { buffer in
            buffer.copyBytes(from: interface.name.utf8.prefix(Int(IFNAMSIZ) - 1))
        }
        return provider.unsafeSetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_BINDTODEVICE, value: name)
        #endif
    }
}
