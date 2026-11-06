import Testing
@testable import ProvisionerPXE

@Suite struct TFTPNegotiationTests {
    private func negotiate(_ options: [(String, String)], fileSize: Int = 1234) -> TFTPNegotiation {
        TFTPNegotiation(requested: options.map { TFTPOption(name: $0.0, value: $0.1) }, fileSize: fileSize)
    }

    @Test func blksizeAccepted() {
        let result = negotiate([("blksize", "1468")])
        #expect(result.blockSize == 1468)
        #expect(result.acknowledged == [TFTPOption(name: "blksize", value: "1468")])
    }

    @Test func blksizeAboveMaximumLowered() {
        let result = negotiate([("blksize", "70000")])
        #expect(result.blockSize == 65464)
        #expect(result.acknowledged == [TFTPOption(name: "blksize", value: "65464")])
    }

    /// RFC 2348: the server may answer only an equal or smaller blksize, so one below 8 is ignored.
    @Test(arguments: ["7", "4", "0", "-1"])
    func blksizeBelowMinimumIgnored(requested: String) {
        let result = negotiate([("blksize", requested)])
        #expect(result.blockSize == 512)
        #expect(result.acknowledged.isEmpty)
    }

    @Test func blksizeMinimumAccepted() {
        #expect(negotiate([("blksize", "8")]).blockSize == 8)
    }

    @Test func repeatedOptionKeepsLastValue() {
        let result = negotiate([("blksize", "1024"), ("timeout", "2"), ("blksize", "1468"), ("timeout", "3")])
        #expect(result.blockSize == 1468)
        #expect(result.timeoutSeconds == 3)
        #expect(result.acknowledged == [
            TFTPOption(name: "blksize", value: "1468"),
            TFTPOption(name: "timeout", value: "3"),
        ])
    }

    @Test func repeatedOptionWithInvalidLastValueIsIgnored() {
        let result = negotiate([("blksize", "1468"), ("blksize", "x")])
        #expect(result.blockSize == 512)
        #expect(result.acknowledged.isEmpty)
    }

    @Test func repeatedTsizeAcknowledgedOnce() {
        #expect(negotiate([("tsize", "0"), ("tsize", "0")]).acknowledged == [TFTPOption(name: "tsize", value: "1234")])
    }

    @Test func tsizeAnswered() {
        #expect(negotiate([("tsize", "0")]).acknowledged == [TFTPOption(name: "tsize", value: "1234")])
    }

    @Test func timeoutInRange() {
        let result = negotiate([("timeout", "3")])
        #expect(result.timeoutSeconds == 3)
        #expect(result.acknowledged == [TFTPOption(name: "timeout", value: "3")])
    }

    @Test func blksizeCappedAtLimit() {
        let result = TFTPNegotiation(requested: [TFTPOption(name: "blksize", value: "16384")], fileSize: 1, maxBlockSize: 1468)
        #expect(result.blockSize == 1468)
        #expect(result.acknowledged == [TFTPOption(name: "blksize", value: "1468")])
    }

    @Test(arguments: [1, 10])
    func timeoutBounds(seconds: Int) {
        #expect(negotiate([("timeout", String(seconds))]).timeoutSeconds == seconds)
    }

    @Test func blksizeNotANumber() {
        let result = negotiate([("blksize", "x")])
        #expect(result.blockSize == 512)
        #expect(result.acknowledged.isEmpty)
    }

    @Test func severalOptionsInRequestOrder() {
        let result = negotiate([("tsize", "0"), ("blksize", "1468"), ("timeout", "2")])
        #expect(result.acknowledged == [
            TFTPOption(name: "tsize", value: "1234"),
            TFTPOption(name: "blksize", value: "1468"),
            TFTPOption(name: "timeout", value: "2"),
        ])
    }

    @Test(arguments: ["0", "11", "255", "x"])
    func timeoutOutOfRange(value: String) {
        let result = negotiate([("timeout", value)])
        #expect(result.timeoutSeconds == nil)
        #expect(result.acknowledged.isEmpty)
    }

    @Test func unknownIgnored() {
        #expect(negotiate([("foo", "bar")]).acknowledged.isEmpty)
    }

    @Test func noOptions() {
        let result = negotiate([])
        #expect(result.blockSize == 512)
        #expect(result.timeoutSeconds == nil)
        #expect(result.acknowledged.isEmpty)
    }
}
