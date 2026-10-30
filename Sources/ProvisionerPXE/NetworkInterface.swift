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

    static func lookup(_ name: String) throws -> NetworkInterface {
        let index = if_nametoindex(name)
        guard index != 0 else { throw PXEServerError.interfaceNotFound(name) }

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { throw PXEServerError.interfaceHasNoIPv4(name) }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == name
            else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return NetworkInterface(name: name, index: index, address: UInt32(bigEndian: ipv4))
        }
        throw PXEServerError.interfaceHasNoIPv4(name)
    }
}
