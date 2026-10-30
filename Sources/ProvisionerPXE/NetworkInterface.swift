import Darwin

public enum PXEServerError: Error, Equatable {
    case interfaceNotFound(String)
    case interfaceHasNoIPv4(String)
}

/// The serving interface: its index for `IP_BOUND_IF` and its first IPv4 address.
struct NetworkInterface: Sendable {
    let name: String
    let index: UInt32
    /// Host byte order.
    let address: UInt32
    let mtu: Int

    static func lookup(_ name: String) throws -> NetworkInterface {
        let index = if_nametoindex(name)
        guard index != 0 else { throw PXEServerError.interfaceNotFound(name) }

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { throw PXEServerError.interfaceHasNoIPv4(name) }
        defer { freeifaddrs(list) }

        var ipv4: UInt32?
        var mtu = 1500
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  String(cString: entry.pointee.ifa_name) == name
            else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET where ipv4 == nil:
                ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            case AF_LINK:
                if let data = entry.pointee.ifa_data {
                    mtu = Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
                }
            default:
                continue
            }
        }
        guard let ipv4 else { throw PXEServerError.interfaceHasNoIPv4(name) }
        return NetworkInterface(name: name, index: index, address: ipv4, mtu: mtu)
    }
}
