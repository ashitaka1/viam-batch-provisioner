import NIOConcurrencyHelpers

/// The MAC each PXE client's DHCP request named for its address. TFTP clients are known only
/// by address, and proxy DHCP never assigns one, so this is how a transfer is tied to a MAC.
/// Holds at most `capacity` addresses, forgetting the oldest first.
final class LeaseTable: Sendable {
    private struct Entries {
        var macs: [UInt32: MACAddress] = [:]
        var order: [UInt32] = []
    }

    private let capacity: Int
    private let entries = NIOLockedValueBox(Entries())

    init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    func record(_ mac: MACAddress, at address: UInt32) {
        entries.withLockedValue { entries in
            if entries.macs.updateValue(mac, forKey: address) == nil {
                entries.order.append(address)
            }
            if entries.order.count > capacity {
                entries.macs[entries.order.removeFirst()] = nil
            }
        }
    }

    func mac(at address: UInt32) -> MACAddress? {
        entries.withLockedValue { $0.macs[address] }
    }
}
