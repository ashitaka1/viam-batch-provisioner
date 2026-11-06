/// The outcome of a read request's options: blksize (RFC 2348), timeout and tsize (RFC 2349).
struct TFTPNegotiation: Equatable, Sendable {
    static let defaultBlockSize = 512
    static let blockSizeRange = 8...65464
    /// RFC 2349 allows up to 255 s; ten caps how long a silent client holds a transfer (five retries).
    static let timeoutRange = 1...10

    var blockSize = Self.defaultBlockSize
    var timeoutSeconds: Int?
    /// Options to confirm in an OACK. Empty means no OACK: data block 1 goes first.
    var acknowledged: [TFTPOption] = []

    /// `maxBlockSize` is the largest block the server can send to this client.
    init(requested: [TFTPOption], fileSize: Int, maxBlockSize: Int = Self.blockSizeRange.upperBound) {
        // A repeated option counts once, with its last value.
        let lastIndex = Dictionary(requested.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { $1 })
        for (index, option) in requested.enumerated() where lastIndex[option.name] == index {
            switch option.name {
            case "blksize":
                // RFC 2348 lets the server answer only an equal or smaller size, so a size below the minimum is ignored.
                guard let size = Int(option.value), size >= Self.blockSizeRange.lowerBound else { continue }
                blockSize = min(size, Self.blockSizeRange.upperBound, maxBlockSize)
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
