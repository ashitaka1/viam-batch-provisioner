import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PXEServerError: Error, Equatable {
    case interfaceNotFound(String)
    case interfaceHasNoIPv4(String)
    /// `start()` was called on a server that is starting or running.
    case alreadyStarted
    /// `start()` was called on a server that `stop()` has ended.
    case stopped
}

/// The serving interface: its name and index for binding, and its first IPv4 address.
struct NetworkInterface: Sendable {
    let name: String
    let index: UInt32
    /// Host byte order.
    let address: UInt32
    let mtu: Int

    static func lookup(_ name: String) throws -> NetworkInterface {
        let index = if_nametoindex(name)
        guard index != 0 else { throw PXEServerError.interfaceNotFound(name) }
        return try NetworkInterface(name: name, index: index, addresses: addresses(of: name))
    }

    /// An address `getifaddrs` lists for an interface.
    enum Address: Equatable {
        /// Host byte order.
        case ipv4(UInt32)
        case link(mtu: Int)
    }

    /// The first IPv4 address, and the MTU from the link entry, else 1500.
    init(name: String, index: UInt32, addresses: [Address]) throws {
        var ipv4: UInt32?
        var mtu = 1500
        for address in addresses {
            switch address {
            case let .ipv4(value) where ipv4 == nil: ipv4 = value
            case .ipv4: continue
            case let .link(value): mtu = value
            }
        }
        guard let ipv4 else { throw PXEServerError.interfaceHasNoIPv4(name) }
        self.init(name: name, index: index, address: ipv4, mtu: mtu)
    }

    init(name: String, index: UInt32, address: UInt32, mtu: Int) {
        self.name = name
        self.index = index
        self.address = address
        self.mtu = mtu
    }

    /// Empty when `getifaddrs` fails.
    private static func addresses(of name: String) -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [Address] = sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            guard let address = entry.pointee.ifa_addr, String(cString: entry.pointee.ifa_name) == name else { return nil }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                return .ipv4(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) })
            #if canImport(Darwin)
            case AF_LINK:
                return entry.pointee.ifa_data.map { .link(mtu: Int($0.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)) }
            #endif
            default:
                return nil
            }
        }
        #if !canImport(Darwin)
        // Linux lists no link-layer MTU through getifaddrs.
        if let text = try? String(contentsOfFile: "/sys/class/net/\(name)/mtu", encoding: .utf8),
           let mtu = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            addresses.append(.link(mtu: mtu))
        }
        #endif
        return addresses
    }
}
