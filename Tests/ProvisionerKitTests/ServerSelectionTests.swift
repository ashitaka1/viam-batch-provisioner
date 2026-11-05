import Foundation
@testable import ProvisionerKit
import Testing

private let bench = DiscoveredServer(name: "bench", baseURL: URL(string: "http://10.0.0.2:8235/")!)

@MainActor
private final class Harness {
    let defaults = UserDefaults(suiteName: "ServerSelectionTests-\(UUID().uuidString)")!
    let continuation: AsyncThrowingStream<[DiscoveredServer], any Error>.Continuation
    private let stream: AsyncThrowingStream<[DiscoveredServer], any Error>

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func selection() -> ServerSelection {
        ServerSelection(defaults: defaults, browse: { [stream] in stream })
    }
}

@MainActor
struct ServerSelectionTests {
    @Test func chosenServerIsRememberedAcrossLaunches() {
        let h = Harness()
        h.selection().select(bench)

        #expect(h.selection().selected == bench)
    }

    @Test func typedAddressBecomesTheSelection() throws {
        let h = Harness()
        let selection = h.selection()

        try selection.connect(host: " 192.168.1.20 ", port: 8235)

        #expect(selection.selected?.baseURL == URL(string: "http://192.168.1.20:8235/"))
        #expect(selection.selected?.name == "192.168.1.20:8235")
    }

    @Test func untypableAddressIsRefusedAndTheSelectionKept() {
        let h = Harness()
        let selection = h.selection()
        selection.select(bench)

        #expect(throws: ServerSelection.InvalidAddress.self) { try selection.connect(host: "bad host", port: 8235) }
        #expect(selection.selected == bench)
    }

    @Test func selectedServerFollowsItsNewAddressWhenBonjourMovesIt() async {
        let h = Harness()
        let selection = h.selection()
        selection.select(bench)
        let browsing = Task { await selection.browse() }
        defer { browsing.cancel() }

        let moved = DiscoveredServer(name: "bench", baseURL: URL(string: "http://10.0.0.9:8235/")!)
        h.continuation.yield([moved])

        _ = await poll { selection.discovered == [moved] }
        #expect(selection.discovered == [moved])
        #expect(selection.selected == moved)
        #expect(h.selection().selected == moved, "the new address is remembered")
    }

    @Test func browseFailureIsReported() async {
        let h = Harness()
        let selection = h.selection()
        h.continuation.finish(throwing: URLError(.notConnectedToInternet))

        await selection.browse()

        #expect(selection.browseError?.hasPrefix("Couldn't look for servers on the network:") == true,
                "got \(selection.browseError ?? "nil")")
    }

    @Test func anotherServerAppearingLeavesTheSelectionAlone() async {
        let h = Harness()
        let selection = h.selection()
        selection.select(bench)
        let browsing = Task { await selection.browse() }
        defer { browsing.cancel() }

        let other = DiscoveredServer(name: "shop", baseURL: URL(string: "http://10.0.0.7:8235/")!)
        h.continuation.yield([other])
        _ = await poll { selection.discovered == [other] }

        #expect(selection.selected == bench)
    }

    @Test func aHalfStoredServerIsNotRestored() {
        let h = Harness()
        h.defaults.set("bench", forKey: "server.name")

        #expect(h.selection().selected == nil)
    }
}
