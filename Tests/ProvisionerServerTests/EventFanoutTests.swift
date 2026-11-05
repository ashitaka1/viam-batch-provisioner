import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

private func withEvents(_ count: Int) async throws -> Provisioner {
    let (provisioner, _) = try makeProvisioner()
    _ = try await provisioner.provision([request("m-1")])
    let stages: [Schemas.InstallStage] = [.lateCommands, .identity, .tooling, .tailscale]
    for stage in stages.prefix(count) {
        _ = try await provisioner.report(report(.progress, stage, name: "m-1"))
    }
    return provisioner
}

private func backlogIDs(_ subscription: EventSubscription) -> [Int?] {
    guard case .events(let events) = subscription.backlog else { return [] }
    return events.map(\.id)
}

@Test func backlogThenLive() async throws {
    let provisioner = try await withEvents(2)

    let subscription = await provisioner.subscribe(after: 1)
    _ = try await provisioner.report(report(.progress, .tailscale, name: "m-1"))

    #expect(backlogIDs(subscription) == [2])
    var live = subscription.live.makeAsyncIterator()
    #expect(await live.next()?.id == 3)
}

@Test func aheadIsResync() async throws {
    let provisioner = try await withEvents(3)

    let subscription = await provisioner.subscribe(after: 99)

    guard case .resync(let latest) = subscription.backlog else {
        Issue.record("expected resync, got \(subscription.backlog)")
        return
    }
    #expect(latest == 3)
}

@Test func caughtUpGetsEmptyBacklog() async throws {
    let provisioner = try await withEvents(3)

    #expect(backlogIDs(await provisioner.subscribe(after: 3)) == [])
}

@Test func nilIsLiveOnly() async throws {
    let provisioner = try await withEvents(2)

    let subscription = await provisioner.subscribe(after: nil)

    #expect(backlogIDs(subscription) == [])
}

@Test func cancelUnsubscribes() async throws {
    let provisioner = try await withEvents(1)
    let subscription = await provisioner.subscribe(after: nil)
    #expect(await provisioner.subscriberCount == 1)

    subscription.cancel()

    try await poll(within: .seconds(2)) { await provisioner.subscriberCount == 0 }
    #expect(await provisioner.subscriberCount == 0, "the fanout still holds a cancelled subscriber")
}
