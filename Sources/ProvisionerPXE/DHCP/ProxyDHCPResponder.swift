/// The socket a request arrived on: the DHCP server port (67) or the PXE boot server port (4011).
enum DHCPListener: Sendable {
    case dhcp
    case pxe
}

/// Proxy DHCP for PXE: RFC 4578 and the PXE 2.1 specification, section 2.2.
/// Answers x86-64 UEFI clients with the boot server and filename, never an address.
struct ProxyDHCPResponder: Sendable {
    let serverAddress: UInt32
    let bootFilename: String

    private static let discover: UInt8 = 1
    private static let offer: UInt8 = 2
    private static let request: UInt8 = 3
    private static let ack: UInt8 = 5
    private static let x86_64EFIArchitectures: Set<UInt16> = [7, 9]
    /// Option 43, sub-option 6 (PXE_DISCOVERY_CONTROL) = 8: boot from the filename in this packet.
    private static let pxeVendorOptions: [UInt8] = [6, 1, 8, 255]

    /// The address a PXE client's DHCP request (to any server) names for itself: option 50, else `ciaddr`.
    func lease(in request: DHCPPacket) -> (address: UInt32, mac: MACAddress)? {
        guard let (mac, _) = Self.pxeClient(request), request.messageType == Self.request else { return nil }
        let requested = request.option(50).flatMap { bytes in
            bytes.count == 4 ? bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : nil
        }
        guard let address = requested ?? (request.ciaddr != 0 ? request.ciaddr : nil) else { return nil }
        return (address, mac)
    }

    /// The MAC and architecture of a direct (unrelayed) request from an x86-64 UEFI PXE client.
    private static func pxeClient(_ request: DHCPPacket) -> (MACAddress, UInt16)? {
        guard request.op == 1,
              request.giaddr == 0,
              let mac = request.clientMAC,
              let vendorClass = request.option(60),
              vendorClass.starts(with: Array("PXEClient".utf8)),
              let arch = request.option(93), !arch.isEmpty, arch.count.isMultiple(of: 2)
        else { return nil }
        // RFC 4578 section 2.1: a list of 16-bit architecture types.
        let architectures = stride(from: 0, to: arch.count, by: 2).map { UInt16(arch[$0]) << 8 | UInt16(arch[$0 + 1]) }
        guard let architecture = architectures.first(where: x86_64EFIArchitectures.contains) else { return nil }
        return (mac, architecture)
    }

    func reply(to request: DHCPPacket, on listener: DHCPListener) -> (packet: DHCPPacket, client: PXEClient?)? {
        guard let (mac, architecture) = Self.pxeClient(request) else { return nil }

        let replyType: UInt8
        switch (listener, request.messageType) {
        case (.dhcp, Self.discover): replyType = Self.offer
        case (.pxe, Self.request): replyType = Self.ack
        default: return nil
        }

        var options = [
            DHCPOption(code: 53, data: [replyType]),
            DHCPOption(code: 54, data: withUnsafeBytes(of: serverAddress.bigEndian, Array.init)),
            DHCPOption(code: 60, data: Array("PXEClient".utf8)),
        ]
        let machineID = request.option(97)
        if let machineID {
            options.append(DHCPOption(code: 97, data: machineID))
        }
        options.append(DHCPOption(code: 43, data: Self.pxeVendorOptions))

        let packet = DHCPPacket(
            op: 2, htype: request.htype, hlen: request.hlen, hops: 0,
            xid: request.xid, secs: 0, flags: request.flags,
            ciaddr: 0, yiaddr: 0, siaddr: serverAddress, giaddr: 0,
            chaddr: request.chaddr, sname: "", file: bootFilename,
            options: options
        )

        guard replyType == Self.offer else { return (packet, nil) }
        let uuid = machineID.flatMap { $0.count == 17 ? Array($0.dropFirst()) : nil }
        return (packet, PXEClient(mac: mac, architecture: architecture, uuid: uuid))
    }
}
