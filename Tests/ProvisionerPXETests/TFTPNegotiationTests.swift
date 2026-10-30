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

    @Test(arguments: [("70000", 65464), ("4", 8)])
    func blksizeClamped(requested: String, expected: Int) {
        let result = negotiate([("blksize", requested)])
        #expect(result.blockSize == expected)
        #expect(result.acknowledged == [TFTPOption(name: "blksize", value: String(expected))])
    }

    @Test func tsizeAnswered() {
        #expect(negotiate([("tsize", "0")]).acknowledged == [TFTPOption(name: "tsize", value: "1234")])
    }

    @Test func timeoutInRange() {
        let result = negotiate([("timeout", "3")])
        #expect(result.timeoutSeconds == 3)
        #expect(result.acknowledged == [TFTPOption(name: "timeout", value: "3")])
    }

    @Test(arguments: ["0", "300", "x"])
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
