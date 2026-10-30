/// The outcome of a read request's options: blksize (RFC 2348), timeout and tsize (RFC 2349).
struct TFTPNegotiation: Equatable, Sendable {
    static let defaultBlockSize = 512
    static let blockSizeRange = 8...65464
    static let timeoutRange = 1...255

    var blockSize = Self.defaultBlockSize
    var timeoutSeconds: Int?
    /// Options to confirm in an OACK. Empty means no OACK: data block 1 goes first.
    var acknowledged: [TFTPOption] = []

    init(requested: [TFTPOption], fileSize: Int) {
        for option in requested {
            switch option.name {
            case "blksize":
                guard let size = Int(option.value) else { continue }
                blockSize = min(max(size, Self.blockSizeRange.lowerBound), Self.blockSizeRange.upperBound)
                acknowledged.append(TFTPOption(name: "blksize", value: String(blockSize)))
            case "timeout":
                guard let seconds = Int(option.value), Self.timeoutRange.contains(seconds) else { continue }
                timeoutSeconds = seconds
                acknowledged.append(option)
            case "tsize":
                acknowledged.append(TFTPOption(name: "tsize", value: String(fileSize)))
            default:
                continue
            }
        }
    }
}
