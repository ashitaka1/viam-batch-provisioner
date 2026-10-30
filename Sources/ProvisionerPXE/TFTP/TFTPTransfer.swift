/// One read transfer, lock-step per RFC 1350: send a block, wait for its ACK, resend on timeout.
struct TFTPTransfer: Sendable {
    enum Action: Equatable, Sendable {
        case sendOptionAck
        case sendBlock(number: UInt16, offset: Int, length: Int)
        case finished
        case failed
        /// A stale or duplicate ACK; keep waiting.
        case none
    }

    private let fileSize: Int
    private let blockSize: Int
    private let sendsOptionAck: Bool
    private let maxRetries: Int

    private var lastSent: Action = .none
    private var awaitedBlock: UInt16 = 0
    private var nextOffset = 0
    private var sentFinalBlock = false
    private var retries = 0

    init(fileSize: Int, negotiation: TFTPNegotiation, maxRetries: Int = 5) {
        self.fileSize = fileSize
        blockSize = negotiation.blockSize
        sendsOptionAck = !negotiation.acknowledged.isEmpty
        self.maxRetries = maxRetries
    }

    mutating func start() -> Action {
        if sendsOptionAck {
            lastSent = .sendOptionAck
            awaitedBlock = 0
            return lastSent
        }
        return sendNextBlock()
    }

    mutating func received(ack block: UInt16) -> Action {
        guard block == awaitedBlock, lastSent != .none else { return .none }
        retries = 0
        if sentFinalBlock {
            lastSent = .finished
            return .finished
        }
        return sendNextBlock()
    }

    mutating func timedOut() -> Action {
        guard retries < maxRetries else { return .failed }
        retries += 1
        return lastSent
    }

    mutating func receivedError() -> Action {
        .failed
    }

    private mutating func sendNextBlock() -> Action {
        let length = min(blockSize, fileSize - nextOffset)
        awaitedBlock &+= 1
        lastSent = .sendBlock(number: awaitedBlock, offset: nextOffset, length: length)
        nextOffset += length
        sentFinalBlock = length < blockSize
        return lastSent
    }
}
