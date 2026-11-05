import Foundation
import NIOCore
import NIOPosix
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

    init() async throws {
        let ports = try await freePorts(3)
        self.ports = ports
        let collector = collector
        sender = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let offerDestination = sender.localAddress!
        service = HelperService(root: root) { interface, bootFilename, root in
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

    /// The boot file named in the next offer the helper sends.
    func nextOfferedBootFile() async -> String? {
        for await offer in collector.offers { return offer.file }
        return nil
    }

    func client() -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func sendDiscover(mac: [UInt8]) async throws {
        try await sender.writeAndFlush(AddressedEnvelope(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: ports[0]), data: discover(mac: mac)))
    }

    func shutdown() async {
        await service.shutdown()
        listener.invalidate()
        try? await sender.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func firstEvent(_ client: HelperClient, timeout: Duration = .seconds(2)) async -> HelperEvent? {
    await withTaskGroup(of: HelperEvent?.self) { group in
        group.addTask {
            for await event in client.events { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Suite(.serialized) struct HelperXPCTests {
    @Test func servesAndSendsOffersToEveryPeer() async throws {
        let rig = try await Rig()
        let server = rig.client()
        let watcher = rig.client()
        #expect(try await watcher.servingInterface() == nil)

        try await server.serve(interface: "lo0", bootFilename: "grubx64.efi")
        #expect(try await watcher.servingInterface() == "lo0")
        try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 0x2A])

        let expected = HelperEvent.offered(mac: "02:00:00:00:00:2a", architecture: 7, uuid: nil)
        #expect(await firstEvent(server) == expected)
        #expect(await firstEvent(watcher) == expected)
        server.invalidate()
        watcher.invalidate()
        await rig.shutdown()
    }

    @Test func servingOutlivesThePeerThatAskedAndStops() async throws {
        let rig = try await Rig()
        let first = rig.client()
        try await first.serve(interface: "lo0", bootFilename: "grubx64.efi")
        first.invalidate()

        let second = rig.client()
        #expect(try await second.servingInterface() == "lo0")
        try await second.stopServing()
        #expect(try await second.servingInterface() == nil)
        // The ports are free again: serving anew binds them.
        try await second.serve(interface: "lo0", bootFilename: "grubx64.efi")
        second.invalidate()
        await rig.shutdown()
    }

    @Test func serveWithAnotherBootFileReplacesTheServer() async throws {
        let rig = try await Rig()
        let client = rig.client()
        try await client.serve(interface: "lo0", bootFilename: "grubx64.efi")
        try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 1])
        #expect(await rig.nextOfferedBootFile() == "grubx64.efi")

        try await client.serve(interface: "lo0", bootFilename: "shimx64.efi")
        try await rig.sendDiscover(mac: [2, 0, 0, 0, 0, 1])
        #expect(await rig.nextOfferedBootFile() == "shimx64.efi")
        client.invalidate()
        await rig.shutdown()
    }

    @Test func serveOnMissingInterfaceFailsAcrossXPC() async throws {
        let rig = try await Rig()
        let client = rig.client()
        do {
            try await client.serve(interface: "nosuch9", bootFilename: "grubx64.efi")
            Issue.record("served on a missing interface")
        } catch let HelperError.serveFailed(detail) {
            #expect(detail.contains("nosuch9"), "\(detail)")
        }
        #expect(try await client.servingInterface() == nil)
        client.invalidate()
        await rig.shutdown()
    }

    @Test func writesAndRemovesTFTPRootFilesAcrossXPC() async throws {
        let rig = try await Rig()
        let client = rig.client()
        try await client.writeFile("grub/grub.cfg", contents: Data("set timeout=5\n".utf8))
        #expect(try Data(contentsOf: rig.root.appendingPathComponent("grub/grub.cfg")) == Data("set timeout=5\n".utf8))

        await #expect(throws: HelperError.invalidPath("../outside")) {
            try await client.writeFile("../outside", contents: Data())
        }
        try await client.removeFile("grub/grub.cfg")
        #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("grub/grub.cfg").path))
        client.invalidate()
        await rig.shutdown()
    }

    @Test func callsAfterInvalidateFail() async throws {
        let rig = try await Rig()
        let client = rig.client()
        client.invalidate()
        await #expect(throws: HelperError.connection("invalidated")) {
            _ = try await client.servingInterface()
        }
        for await _ in client.events {}
        await rig.shutdown()
    }
}
