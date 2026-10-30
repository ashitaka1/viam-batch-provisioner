import NIOCore

struct TFTPOption: Equatable, Sendable {
    var name: String
    var value: String
}

enum TFTPErrorCode: UInt16, Sendable {
    case notDefined = 0
    case fileNotFound = 1
    case accessViolation = 2
    case illegalOperation = 4
    case unknownTID = 5
    case optionRefused = 8
}

/// TFTP packets (RFC 1350) with option acknowledgement (RFC 2347).
enum TFTPPacket: Equatable, Sendable {
    case readRequest(filename: String, mode: String, options: [TFTPOption])
    case writeRequest(filename: String, mode: String)
    case data(block: UInt16, payload: ByteBuffer)
    case ack(block: UInt16)
    case error(code: UInt16, message: String)
    case optionAck([TFTPOption])

    init?(buffer: ByteBuffer) {
        var buffer = buffer
        guard let opcode = buffer.readInteger(as: UInt16.self) else { return nil }
        switch opcode {
        case 1, 2:
            guard let filename = Self.readString(&buffer),
                  let mode = Self.readString(&buffer)
            else { return nil }
            if opcode == 2 {
                self = .writeRequest(filename: filename, mode: mode)
                return
            }
            guard let options = Self.readOptions(&buffer) else { return nil }
            self = .readRequest(filename: filename, mode: mode, options: options)
        case 3:
            guard let block = buffer.readInteger(as: UInt16.self) else { return nil }
            self = .data(block: block, payload: buffer)
        case 4:
            guard let block = buffer.readInteger(as: UInt16.self) else { return nil }
            self = .ack(block: block)
        case 5:
            guard let code = buffer.readInteger(as: UInt16.self),
                  let message = Self.readString(&buffer)
            else { return nil }
            self = .error(code: code, message: message)
        case 6:
            guard let options = Self.readOptions(&buffer) else { return nil }
            self = .optionAck(options)
        default:
            return nil
        }
    }

    func encoded() -> ByteBuffer {
        var buffer = ByteBuffer()
        switch self {
        case let .readRequest(filename, mode, options):
            buffer.writeInteger(UInt16(1))
            Self.writeString(filename, to: &buffer)
            Self.writeString(mode, to: &buffer)
            Self.writeOptions(options, to: &buffer)
        case let .writeRequest(filename, mode):
            buffer.writeInteger(UInt16(2))
            Self.writeString(filename, to: &buffer)
            Self.writeString(mode, to: &buffer)
        case let .data(block, payload):
            buffer.writeInteger(UInt16(3))
            buffer.writeInteger(block)
            buffer.writeImmutableBuffer(payload)
        case let .ack(block):
            buffer.writeInteger(UInt16(4))
            buffer.writeInteger(block)
        case let .error(code, message):
            buffer.writeInteger(UInt16(5))
            buffer.writeInteger(code)
            Self.writeString(message, to: &buffer)
        case let .optionAck(options):
            buffer.writeInteger(UInt16(6))
            Self.writeOptions(options, to: &buffer)
        }
        return buffer
    }

    private static func readString(_ buffer: inout ByteBuffer) -> String? {
        guard let end = buffer.readableBytesView.firstIndex(of: 0),
              let string = buffer.readString(length: end - buffer.readerIndex)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 1)
        return string
    }

    private static func readOptions(_ buffer: inout ByteBuffer) -> [TFTPOption]? {
        var options: [TFTPOption] = []
        while buffer.readableBytes > 0 {
            guard let name = readString(&buffer), let value = readString(&buffer) else { return nil }
            options.append(TFTPOption(name: name.lowercased(), value: value))
        }
        return options
    }

    private static func writeString(_ string: String, to buffer: inout ByteBuffer) {
        buffer.writeString(string)
        buffer.writeInteger(UInt8(0))
    }

    private static func writeOptions(_ options: [TFTPOption], to buffer: inout ByteBuffer) {
        for option in options {
            writeString(option.name, to: &buffer)
            writeString(option.value, to: &buffer)
        }
    }
}
