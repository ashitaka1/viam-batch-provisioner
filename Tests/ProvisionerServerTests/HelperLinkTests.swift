#if canImport(ProvisionerHelperXPC)
import Foundation
import os
import ProvisionerHelperXPC
@testable import ProvisionerServer
import Testing

private let mac = "aa:bb:cc:00:00:01"

@Test func helperEventsMapToObservations() {
    #expect(PXEObservation(.offered(mac: mac, architecture: 7, uuid: nil)) == .offered(mac: mac))
    #expect(PXEObservation(.fileSent(filename: "hwe-vmlinuz", clientAddress: "10.0.0.5", mac: mac, bytes: 10))
        == .fileSent(filename: "hwe-vmlinuz", mac: mac))
    #expect(PXEObservation(.fileSent(filename: "grubx64.efi", clientAddress: "10.0.0.5", mac: nil, bytes: 10))
        == .fileSent(filename: "grubx64.efi", mac: nil))
}

/// Stands in for the helper: sends `event` to a peer once it asks `servingInterface`,
/// and refuses the first `refusals` connections.
private final class FakeHelper: NSObject, NSXPCListenerDelegate, ProvisionerHelperProtocol, Sendable {
    let event: HelperEvent
    private let refusals: OSAllocatedUnfairLock<Int>
    private let connection = OSAllocatedUnfairLock<NSXPCConnection?>(uncheckedState: nil)

    init(event: HelperEvent, refusals: Int = 0) {
        self.event = event
        self.refusals = OSAllocatedUnfairLock(initialState: refusals)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if refusals.withLock({ left in
            defer { left -= 1 }
            return left > 0
        }) { return false }
        connection.exportedInterface = ProvisionerHelperXPC.helperInterface()
        connection.exportedObject = self
        connection.remoteObjectInterface = ProvisionerHelperXPC.eventsInterface()
        self.connection.withLockUnchecked { $0 = connection }
        connection.resume()
        return true
    }

    func servingInterface(reply: @escaping @Sendable (String?) -> Void) {
        reply(nil)
        guard let data = try? event.encoded(),
              let peer = connection.withLockUnchecked({ $0 }),
              let events = peer.remoteObjectProxy as? any ProvisionerHelperEventsProtocol else { return }
        events.helperEvent(data)
    }

    func serve(interface: String, bootFilename: String, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
    func stopServing(reply: @escaping @Sendable () -> Void) { reply() }
    func writeFile(_ path: String, contents: Data, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
    func removeFile(_ path: String, reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
}

private func linkedSteps(refusals: Int) async throws -> [String] {
    let (provisioner, _) = try makeProvisioner(bindings: FixedBindings())
    _ = try await provisioner.provision([request("m-1")])
    let helper = FakeHelper(event: .offered(mac: mac, architecture: 7, uuid: nil), refusals: refusals)
    let listener = NSXPCListener.anonymous()
    listener.delegate = helper
    listener.resume()
    defer { listener.invalidate() }
    let endpoint = listener.endpoint
    let client = HelperClient { NSXPCConnection(listenerEndpoint: endpoint) }
    let link = Task { await linkHelper(client, to: provisioner, logger: testLogger, retry: .milliseconds(20)) }
    try await poll(within: .seconds(5)) {
        ((try? await provisioner.entry("m-1").steps) ?? nil)?.isEmpty == false
    }
    client.invalidate()
    await link.value
    return try await provisioner.entry("m-1").steps?.map(\.step.rawValue) ?? []
}

@Test func linkForwardsEventsAfterRegistering() async throws {
    #expect(try await linkedSteps(refusals: 0) == ["found"])
}

@Test func linkRetriesUntilTheHelperAccepts() async throws {
    #expect(try await linkedSteps(refusals: 2) == ["found"])
}
#endif
