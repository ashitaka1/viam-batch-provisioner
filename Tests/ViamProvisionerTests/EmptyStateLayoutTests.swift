import Foundation
@testable import ProvisionerKit
import SwiftUI
import Testing
@testable import ViamProvisioner

/// A server the tests never connect to.
private struct UnusedSource: QueueSource {
    struct Unused: Error {}
    func queue() async throws -> QueueSnapshot { throw Unused() }
    func eventFrames(after id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, any Error> { throw Unused() }
    func entry(named name: String) async throws(ProvisionerError) -> QueueEntry { throw .unexpectedResponse(status: 0) }
    func remove(named name: String) async throws(ProvisionerError) {}
}

private let pane = CGSize(width: 600, height: 480)

@MainActor private func height(of view: some View, in proposal: CGSize) -> CGFloat {
    NSHostingController(rootView: view).sizeThatFits(in: proposal).height
}

// The detail pane centres what doesn't fill it, which would float the counts bar mid-pane.
// These check that each column fills the pane, not where its content sits within it.

/// The queue before its first snapshot, showing "Connecting…".
@MainActor @Test func emptyQueueFillsThePane() {
    let queue = QueueModel(serverName: "bench:8235", source: UnusedSource())
    let column = QueueColumn(queue: queue, onlineAt: [:], selection: .constant(nil), remove: { _ in })
    #expect(abs(height(of: column, in: pane) - pane.height) < 1)
}

@MainActor @Test func emptyHistoryFillsThePane() {
    let history = BatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    let view = HistoryView(history: history, queue: nil, onlineAt: [:])
    #expect(abs(height(of: view, in: pane) - pane.height) < 1)
}

/// The window's minimum size is its content's size at a zero proposal; the reconnect banner
/// must not raise it past the window, or the sidebar and table end up off screen.
@MainActor @Test func reconnectBannerKeepsTheQueueColumnShortWhenSqueezed() async throws {
    let queue = QueueModel(serverName: "bench:8235", source: UnusedSource())
    let (states, input) = AsyncStream.makeStream(of: FeedState.self)
    let (updates, _) = AsyncStream.makeStream(of: QueueUpdate.self)
    let following = Task { await queue.follow(updates: updates, states: states) }
    defer { following.cancel() }
    input.yield(.waiting(retryIn: .seconds(5), lastError: URLError(.cannotConnectToHost)))
    var tries = 0
    while queue.connection == .connecting && tries < 200 {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    guard case .waiting = queue.connection else { Issue.record("the queue never showed the banner's state"); return }

    let column = QueueColumn(queue: queue, onlineAt: [:], selection: .constant(nil), remove: { _ in })
    // The banner, counts bar and empty state, one line each, take about 200 pt.
    #expect(height(of: column, in: .zero) < 400)
}
