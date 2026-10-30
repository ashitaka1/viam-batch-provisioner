import NIOCore

struct DHCPOption: Equatable, Sendable {
    var code: UInt8
    var data: [UInt8]
}

/// A BOOTP/DHCP message (RFC 2131, options per RFC 2132).
struct DHCPPacket: Equatable, Sendable {
    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    static let headerLength = 236

    var op: UInt8
    var htype: UInt8
    var hlen: UInt8
    var hops: UInt8
    var xid: UInt32
    var secs: UInt16
    var flags: UInt16
    var ciaddr: UInt32
    var yiaddr: UInt32
    var siaddr: UInt32
    var giaddr: UInt32
    var chaddr: [UInt8]
    var sname: String
    var file: String
    var options: [DHCPOption]

    init(
        op: UInt8, htype: UInt8, hlen: UInt8, hops: UInt8,
        xid: UInt32, secs: UInt16, flags: UInt16,
        ciaddr: UInt32, yiaddr: UInt32, siaddr: UInt32, giaddr: UInt32,
        chaddr: [UInt8], sname: String, file: String, options: [DHCPOption]
    ) {
        self.op = op
        self.htype = htype
        self.hlen = hlen
        self.hops = hops
        self.xid = xid
        self.secs = secs
        self.flags = flags
        self.ciaddr = ciaddr
        self.yiaddr = yiaddr
        self.siaddr = siaddr
        self.giaddr = giaddr
        self.chaddr = chaddr
        self.sname = sname
        self.file = file
        self.options = options
    }

    init?(buffer: ByteBuffer) {
        var buffer = buffer
        guard buffer.readableBytes >= Self.headerLength + Self.magicCookie.count,
              let op = buffer.readInteger(as: UInt8.self),
              let htype = buffer.readInteger(as: UInt8.self),
              let hlen = buffer.readInteger(as: UInt8.self),
              let hops = buffer.readInteger(as: UInt8.self),
              let xid = buffer.readInteger(as: UInt32.self),
              let secs = buffer.readInteger(as: UInt16.self),
              let flags = buffer.readInteger(as: UInt16.self),
              let ciaddr = buffer.readInteger(as: UInt32.self),
              let yiaddr = buffer.readInteger(as: UInt32.self),
              let siaddr = buffer.readInteger(as: UInt32.self),
              let giaddr = buffer.readInteger(as: UInt32.self),
              let chaddr = buffer.readBytes(length: 16),
              let sname = buffer.readBytes(length: 64),
              let file = buffer.readBytes(length: 128),
              buffer.readBytes(length: 4) == Self.magicCookie
        else { return nil }

        var options: [DHCPOption] = []
        parsing: while let code = buffer.readInteger(as: UInt8.self) {
            switch code {
            case 0:
                continue
            case 255:
                break parsing
            default:
                guard let length = buffer.readInteger(as: UInt8.self),
                      let data = buffer.readBytes(length: Int(length))
                else { return nil }
                options.append(DHCPOption(code: code, data: data))
            }
        }

        self.init(
            op: op, htype: htype, hlen: hlen, hops: hops,
            xid: xid, secs: secs, flags: flags,
            ciaddr: ciaddr, yiaddr: yiaddr, siaddr: siaddr, giaddr: giaddr,
            chaddr: chaddr, sname: Self.string(fromField: sname), file: Self.string(fromField: file),
            options: options
        )
    }

    func encoded() -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(op)
        buffer.writeInteger(htype)
        buffer.writeInteger(hlen)
        buffer.writeInteger(hops)
        buffer.writeInteger(xid)
        buffer.writeInteger(secs)
        buffer.writeInteger(flags)
        buffer.writeInteger(ciaddr)
        buffer.writeInteger(yiaddr)
        buffer.writeInteger(siaddr)
        buffer.writeInteger(giaddr)
        buffer.writeBytes(Self.field(chaddr, length: 16))
        buffer.writeBytes(Self.field(Array(sname.utf8), length: 64))
        buffer.writeBytes(Self.field(Array(file.utf8), length: 128))
        buffer.writeBytes(Self.magicCookie)
        for option in options {
            buffer.writeInteger(option.code)
            buffer.writeInteger(UInt8(option.data.count))
            buffer.writeBytes(option.data)
        }
        buffer.writeInteger(UInt8(255))
        return buffer
    }

    func option(_ code: UInt8) -> [UInt8]? {
        options.first { $0.code == code }?.data
    }

    var messageType: UInt8? {
        option(53)?.first
    }

    var clientMAC: MACAddress? {
        guard htype == 1, hlen == 6 else { return nil }
        return MACAddress(bytes: chaddr.prefix(6))
    }

    private static func field(_ bytes: [UInt8], length: Int) -> [UInt8] {
        Array(bytes.prefix(length)) + [UInt8](repeating: 0, count: max(0, length - bytes.count))
    }

    private static func string(fromField bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
