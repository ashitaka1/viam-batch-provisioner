import Testing
@testable import ProvisionerPXE

@Suite struct TFTPTransferTests {
    /// A transfer at 512-byte blocks without an OACK, or at `blksize` after one.
    private func transfer(size: Int, blksize: Int? = nil) -> TFTPTransfer {
        let requested = blksize.map { [TFTPOption(name: "blksize", value: String($0))] } ?? []
        return TFTPTransfer(fileSize: size, negotiation: TFTPNegotiation(requested: requested, fileSize: size))
    }

    @Test func smallFileNoOptions() {
        var t = transfer(size: 700)
        #expect(t.start() == .sendBlock(number: 1, offset: 0, length: 512))
        #expect(t.received(ack: 1) == .sendBlock(number: 2, offset: 512, length: 188))
        #expect(t.received(ack: 2) == .finished)
    }

    @Test func optionAckFirst() {
        var t = transfer(size: 2000, blksize: 1468)
        #expect(t.start() == .sendOptionAck)
        #expect(t.received(ack: 0) == .sendBlock(number: 1, offset: 0, length: 1468))
    }

    @Test func nonZeroAckBeforeOptionAckIgnored() {
        var t = transfer(size: 2000, blksize: 1468)
        _ = t.start()
        #expect(t.received(ack: 1) == TFTPTransfer.Action.none)
    }

    @Test func exactMultipleEndsWithEmptyBlock() {
        var t = transfer(size: 1024)
        #expect(t.start() == .sendBlock(number: 1, offset: 0, length: 512))
        #expect(t.received(ack: 1) == .sendBlock(number: 2, offset: 512, length: 512))
        #expect(t.received(ack: 2) == .sendBlock(number: 3, offset: 1024, length: 0))
        #expect(t.received(ack: 3) == .finished)
    }

    @Test func emptyFile() {
        var t = transfer(size: 0)
        #expect(t.start() == .sendBlock(number: 1, offset: 0, length: 0))
        #expect(t.received(ack: 1) == .finished)
    }

    @Test func duplicateAckIgnored() {
        var t = transfer(size: 2000)
        _ = t.start()
        #expect(t.received(ack: 1) == .sendBlock(number: 2, offset: 512, length: 512))
        #expect(t.received(ack: 1) == TFTPTransfer.Action.none)
    }

    @Test func prematureAckIgnored() {
        var t = transfer(size: 2000)
        _ = t.start()
        #expect(t.received(ack: 99) == TFTPTransfer.Action.none)
        #expect(t.received(ack: 1) == .sendBlock(number: 2, offset: 512, length: 512))
    }

    @Test func blockNumberWraps() {
        let size = 512 * 65537 + 10
        var t = transfer(size: size)
        var action = t.start()
        var lastOffsetEnd = 0
        var sawWrap = false
        while case let .sendBlock(number, offset, length) = action {
            if number == 0 {
                #expect(offset == 512 * 65535, "block 0 after the wrap starts at \(offset)")
                sawWrap = true
            }
            lastOffsetEnd = offset + length
            action = t.received(ack: number)
        }
        #expect(sawWrap, "block numbers never wrapped to 0")
        #expect(action == .finished)
        #expect(lastOffsetEnd == size, "sent \(lastOffsetEnd) of \(size) bytes")
    }

    @Test func timeoutResends() {
        var t = transfer(size: 2000)
        _ = t.start()
        let second = t.received(ack: 1)
        #expect(t.timedOut() == second)
    }

    @Test func givesUpAfterRetries() {
        var t = transfer(size: 2000)
        _ = t.start()
        for _ in 0..<4 { _ = t.timedOut() }
        _ = t.received(ack: 1)
        for attempt in 1...5 {
            #expect(t.timedOut() != .failed, "failed on retry \(attempt) after an ack reset the count")
        }
        #expect(t.timedOut() == .failed)
    }
}
