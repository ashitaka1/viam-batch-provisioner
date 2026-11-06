import Foundation
import NIOCore
import NIOPosix
import os
import ProvisionerHelperCore
import ProvisionerHelperXPC
import Testing
@testable import ProvisionerPXE

/// `count` distinct UDP ports that were free a moment ago.
private func freePorts(_ count: Int) async throws -> [Int] {
    var channels: [any Channel] = []
    for _ in 0..<count {
        channels.append(try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "0.0.0.0", port: 0).get())
    }
    let ports = channels.map { $0.localAddress!.port! }
    for channel in channels { try await channel.close() }
    return ports
}

private func discover(mac: [UInt8]) -> ByteBuffer {
    DHCPPacket(
        op: 1, htype: 1, hlen: 6, hops: 0, xid: 1, secs: 0, flags: 0x8000,
        ciaddr: 0, yiaddr: 0, siaddr: 0, giaddr: 0,
        chaddr: mac + [UInt8](repeating: 0, count: 10), sname: "", file: "",
        options: [
            DHCPOption(code: 53, data: [1]),
            DHCPOption(code: 60, data: Array("PXEClient:Arch:00007".utf8)),
            DHCPOption(code: 93, data: [0, 7]),
        ]
    ).encoded()
}

/// Collects the datagrams a channel receives.
private final class OfferCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let offers: AsyncStream<DHCPPacket>
    private let continuation: AsyncStream<DHCPPacket>.Continuation

    init() {
        (offers, continuation) = AsyncStream.makeStream()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if let packet = DHCPPacket(buffer: unwrapInboundIn(data).data) { continuation.yield(packet) }
    }
}

/// A helper service behind an anonymous listener on lo0 with free ports, and a client connected to it.
private final class Rig: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service: HelperService
    let listener: NSXPCListener
    let ports: [Int]
    let sender: any Channel
    let collector = OfferCollector()
    private let configureCount = OSAllocatedUnfairLock(initialState: 0)

    /// How many `PXEServer`s the service has configured.
    var serversConfigured: Int { configureCount.withLock { $0 } }

    init(acceptPeer: @escaping @Sendable (NSXPCConnection) -> Bool = { _ in true }) async throws {
        let ports = try await freePorts(3)
        self.ports = ports
        let collector = collector
        sender = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let offerDestination = sender.localAddress!
        let configureCount = configureCount
        service = HelperService(root: root, acceptPeer: acceptPeer) { interface, bootFilename, root in
            configureCount.withLock { $0 += 1 }
            var configuration = PXEConfiguration(interface: interface, tftpRoot: root)
            configuration.bootFilename = bootFilename
            (configuration.dhcpPort, configuration.pxePort, configuration.tftpPort) = (ports[0], ports[1], ports[2])
            configuration.offerDestination = offerDestination
            return configuration
        }
        listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
    }

    func client() -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func sendDiscover(mac: [UInt8]) async throws {
        try await sender.writeAndFlush(AddressedEnvelope(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: ports[0]), data: discover(mac: mac)))
    }

    /// The boot file named in the next offer the helper sends.
    func nextOfferedBootFile() async -> Outcome<String> {
        await first(of: collector.offers).map(\.file)
    }

    func shutdown() async {
        await service.shutdown()
        listener.invalidate()
        try? await sender.close()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Runs `body` against a fresh rig and shuts it down whether or not `body` throws.
private func withRig(
    acceptPeer: @escaping @Sendable (NSXPCConnection) -> Bool = { _ in true },
    _ body: (Rig) async throws -> Void
) async throws {
    let rig = try await Rig(acceptPeer: acceptPeer)
    do {
        try await body(rig)
    } catch {
        await rig.shutdown()
        throw error
    }
    await rig.shutdown()
}

private enum Outcome<Element: Sendable & Equatable>: Equatable, Sendable {
    case element(Element)
    case finished
    case timedOut

    func map<T>(_ transform: (Element) -> T) -> Outcome<T> {
        switch self {
        case let .element(element): .element(transform(element))
        case .finished: .finished
        case .timedOut: .timedOut
        }
    }
}

/// The stream's next element, or whether it finished or stayed silent for `timeout`.
private func first<Element: Sendable & Equatable>(
    of stream: AsyncStream<Element>, timeout: Duration = .seconds(2)
) async -> Outcome<Element> {
    await withTaskGroup(of: Outcome<Element>.self) { group in
        group.addTask {
            for await element in stream { return .element(element) }
            return .finished
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .timedOut
        }
        let outcome = await group.next() ?? .timedOut
        group.cancelAll()
        return outcome
    }
}

@Suite(.serialized) struct HelperXPCTests {
    @Test func servesAndSendsOffersToEveryPeer() async throws {
        try await withRig { rig in
            let server = rig.client()
            let watcher = rig.client()
            defer { server.invalidate(); watcher.invalidate() }
            #expect(try await watcher.servingInterface() == nil)

            try await server.serve(interface: "lo0", bootFilename: "grubx64.efi")
            #expect(try await watcher.servingInterface() == "lo0")
            try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 0x2A])

            let expected = HelperEvent.offered(mac: "02:00:00:00:00:2a", architecture: 7, uuid: nil)
            #expect(await first(of: server.events) == .element(expected))
            #expect(await first(of: watcher.events) == .element(expected))
        }
    }

    @Test func aDisconnectedPeerLeavesOthersReceiving() async throws {
        try await withRig { rig in
            let leaving = rig.client()
            let staying = rig.client()
            defer { staying.invalidate() }
            try await leaving.serve(interface: "lo0", bootFilename: "grubx64.efi")
            #expect(try await staying.servingInterface() == "lo0")
            leaving.invalidate()

            try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 7])
            #expect(await first(of: staying.events) == .element(.offered(mac: "02:00:00:00:00:07", architecture: 7, uuid: nil)))
        }
    }

    @Test func servingOutlivesThePeerThatAskedAndStops() async throws {
        try await withRig { rig in
            let first = rig.client()
            try await first.serve(interface: "lo0", bootFilename: "grubx64.efi")
            first.invalidate()

            let second = rig.client()
            defer { second.invalidate() }
            #expect(try await second.servingInterface() == "lo0")
            try await second.stopServing()
            #expect(try await second.servingInterface() == nil)
            try await second.serve(interface: "lo0", bootFilename: "grubx64.efi")
            #expect(try await second.servingInterface() == "lo0", "serving again after a stop failed to rebind")
        }
    }

    @Test func serveWithTheSameArgumentsKeepsTheRunningServer() async throws {
        try await withRig { rig in
            let client = rig.client()
            defer { client.invalidate() }
            try await client.serve(interface: "lo0", bootFilename: "grubx64.efi")
            try await client.serve(interface: "lo0", bootFilename: "grubx64.efi")
            #expect(rig.serversConfigured == 1)
        }
    }

    @Test func serveWithAnotherBootFileReplacesTheServer() async throws {
        try await withRig { rig in
            let client = rig.client()
            defer { client.invalidate() }
            try await client.serve(interface: "lo0", bootFilename: "grubx64.efi")
            try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 1])
            #expect(await rig.nextOfferedBootFile() == .element("grubx64.efi"))

            try await client.serve(interface: "lo0", bootFilename: "shimx64.efi")
            try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 1])
            #expect(await rig.nextOfferedBootFile() == .element("shimx64.efi"))
        }
    }

    /// Without serial operations, overlapping serves race to bind the same ports and one fails.
    @Test func concurrentCallsRunInArrivalOrder() async throws {
        try await withRig { rig in
            let client = rig.client()
            defer { client.invalidate() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for bootFile in ["a.efi", "b.efi", "c.efi", "d.efi"] {
                    group.addTask { try await client.serve(interface: "lo0", bootFilename: bootFile) }
                }
                try await group.waitForAll()
            }
            #expect(try await client.servingInterface() == "lo0")
            try await client.stopServing()
            #expect(try await client.servingInterface() == nil)
        }
    }

    @Test func serveOnMissingInterfaceFailsAcrossXPC() async throws {
        try await withRig { rig in
            let client = rig.client()
            defer { client.invalidate() }
            do {
                try await client.serve(interface: "nosuch9", bootFilename: "grubx64.efi")
                Issue.record("served on a missing interface")
            } catch let HelperError.serveFailed(detail) {
                #expect(detail.contains("nosuch9"), "\(detail)")
            }
            #expect(try await client.servingInterface() == nil)
        }
    }

    @Test func writesAndRemovesTFTPRootFilesAcrossXPC() async throws {
        try await withRig { rig in
            let client = rig.client()
            defer { client.invalidate() }
            try await client.writeFile("grub/grub.cfg", contents: Data("set timeout=5\n".utf8))
            #expect(try Data(contentsOf: rig.root.appendingPathComponent("grub/grub.cfg")) == Data("set timeout=5\n".utf8))

            await #expect(throws: HelperError.invalidPath("../outside")) {
                try await client.writeFile("../outside", contents: Data())
            }
            try await client.removeFile("grub/grub.cfg")
            #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("grub/grub.cfg").path))
        }
    }

    @Test func refusedPeerGetsAConnectionError() async throws {
        try await withRig(acceptPeer: { _ in false }) { rig in
            let client = rig.client()
            defer { client.invalidate() }
            await #expect { try await client.writeFile("grub/grub.cfg", contents: Data("x".utf8)) } throws: { error in
                if case HelperError.connection = error { true } else { false }
            }
            #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("grub/grub.cfg").path))
        }
    }

    @Test func invalidateFinishesEventsAndFailsLaterCalls() async throws {
        try await withRig { rig in
            let client = rig.client()
            client.invalidate()
            #expect(await first(of: client.events) == .finished)
            await #expect(throws: HelperError.invalidated) { _ = try await client.servingInterface() }
        }
    }
}
