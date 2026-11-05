import Testing
@testable import ProvisionerPXE

@Suite struct LeaseTableTests {
    let first = MACAddress(bytes: [2, 0, 0, 0, 0, 1])!
    let second = MACAddress(bytes: [2, 0, 0, 0, 0, 2])!

    @Test func latestRequestWins() {
        let table = LeaseTable()
        table.record(first, at: 10)
        table.record(second, at: 10)
        #expect(table.mac(at: 10) == second)
    }

    @Test func forgetsOldestBeyondCapacity() {
        let table = LeaseTable(capacity: 2)
        table.record(first, at: 10)
        table.record(second, at: 11)
        table.record(second, at: 12)
        #expect(table.mac(at: 10) == nil, "the oldest address survived")
        #expect(table.mac(at: 11) == second)
        #expect(table.mac(at: 12) == second)
    }

    /// Age counts from an address's first request, so a client re-requesting can't keep a stale entry alive.
    @Test func reRecordingAnAddressKeepsItsAge() {
        let table = LeaseTable(capacity: 2)
        table.record(first, at: 10)
        table.record(second, at: 11)
        table.record(first, at: 10)
        table.record(second, at: 12)
        #expect(table.mac(at: 10) == nil)
        #expect(table.mac(at: 11) == second)
    }
}
