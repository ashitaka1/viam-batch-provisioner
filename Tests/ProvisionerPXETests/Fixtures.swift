@testable import ProvisionerPXE

let fixtureMAC: [UInt8] = [0x02, 0x00, 0x5E, 0x10, 0x20, 0x30]
let fixtureUUID: [UInt8] = Array(0x10..<0x20)

/// A DHCPDISCOVER shaped like the one x86-64 UEFI firmware broadcasts.
func pxeDiscover(
    mac: [UInt8] = fixtureMAC,
    arch: UInt16 = 7,
    uuid: [UInt8]? = fixtureUUID,
    vendorClass: String? = "PXEClient:Arch:00007:UNDI:003016",
    messageType: UInt8 = 1,
    giaddr: UInt32 = 0
) -> DHCPPacket {
    var options = [DHCPOption(code: 53, data: [messageType])]
    if let vendorClass {
        options.append(DHCPOption(code: 60, data: Array(vendorClass.utf8)))
    }
    options.append(DHCPOption(code: 93, data: [UInt8(arch >> 8), UInt8(arch & 0xFF)]))
    if let uuid {
        options.append(DHCPOption(code: 97, data: [0] + uuid))
    }
    return DHCPPacket(
        op: 1, htype: 1, hlen: 6, hops: 0,
        xid: 0xDEAD_BEEF, secs: 4, flags: 0x8000,
        ciaddr: 0, yiaddr: 0, siaddr: 0, giaddr: giaddr,
        chaddr: mac + [UInt8](repeating: 0, count: 16 - mac.count),
        sname: "", file: "",
        options: options
    )
}
