#if os(macOS)
import Foundation
import HummingbirdTesting
import NIOCore
import NIOPosix
import ProvisionerAPI
@testable import ProvisionerPXE
@testable import ProvisionerServer
import ServiceLifecycle
import Testing

private let boundMAC: [UInt8] = [0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01]

/// A UDP socket on 127.0.0.1 that plays the PXE client.
private final class PXETestClient: Sendable {
    private let channel: any Channel
    private let received: AsyncStream<AddressedEnvelope<ByteBuffer>>

    private final class Collect: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        let continuation: AsyncStream<AddressedEnvelope<ByteBuffer>>.Continuation
        init(_ continuation: AsyncStream<AddressedEnvelope<ByteBuffer>>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { continuation.yield(unwrapInboundIn(data)) }
    }

    init() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AddressedEnvelope<ByteBuffer>.self)
        received = stream
        channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Collect(continuation)) }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    var address: SocketAddress { channel.localAddress! }

    func close() async { try? await channel.close() }

    func send(_ buffer: ByteBuffer, to address: SocketAddress) async throws {
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer))
    }

    func send(_ buffer: ByteBuffer, port: Int) async throws {
        try await send(buffer, to: SocketAddress(ipAddress: "127.0.0.1", port: port))
    }

    func receive(timeout: Duration = .seconds(2)) async -> AddressedEnvelope<ByteBuffer>? {
        let received = received
        return await withTaskGroup(of: AddressedEnvelope<ByteBuffer>?.self) { group in
            group.addTask { await received.first { _ in true } }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A DHCP message from `boundMAC`: a discover, or a request naming 127.0.0.1, which
    /// is how the TFTP server learns the MAC behind a transfer from that address.
    func dhcp(messageType: UInt8, port: Int) async throws {
        var options = [DHCPOption(code: 53, data: [messageType])]
        if messageType == 3 { options.append(DHCPOption(code: 50, data: [127, 0, 0, 1])) }
        options += [DHCPOption(code: 60, data: Array("PXEClient:Arch:00007:UNDI:003016".utf8)),
                    DHCPOption(code: 93, data: [0, 7])]
        let packet = DHCPPacket(op: 1, htype: 1, hlen: 6, hops: 0, xid: 1, secs: 0, flags: 0x8000,
                                ciaddr: 0, yiaddr: 0, siaddr: 0, giaddr: 0,
                                chaddr: boundMAC + [UInt8](repeating: 0, count: 10), sname: "", file: "", options: options)
        try await send(packet.encoded(), port: port)
    }

    /// The first packet the server answers a TFTP read of `filename` with, acknowledging a data block.
    func read(_ filename: String, port: Int) async throws -> TFTPPacket? {
        try await send(TFTPPacket.readRequest(filename: filename, mode: "octet", options: []).encoded(), port: port)
        guard let envelope = await receive(), let packet = TFTPPacket(buffer: envelope.data) else { return nil }
        if case let .data(block, _) = packet {
            try await send(TFTPPacket.ack(block: block).encoded(), to: envelope.remoteAddress)
        }
        return packet
    }
}

/// A `PXEService` on lo0 with ephemeral ports, offering to `client`, running in a service group
/// until `body` returns. `<data>/tftp` holds `hwe-vmlinuz` and `hwe-initrd`, and `<data>/outside.txt`
/// sits outside it; `m-1` is queued and bound to `boundMAC`. `tftpRootIsAFile` puts a file where the
/// TFTP root goes. After `body`, the service must shut down within 2 s and report itself down.
private func withPXEService(
    interface: String = "lo0", retry: Duration = .seconds(30), tftpRootIsAFile: Bool = false,
    configure: @escaping @Sendable (inout PXEConfiguration) -> Void = { _ in },
    _ body: (PXEService, Provisioner, PXETestClient) async throws -> Void
) async throws {
    let data = try temporaryDirectory()
    let (provisioner, _) = try makeProvisioner(data, bindings: FixedBindings())
    _ = try await provisioner.provision([request("m-1")])
    let tftp = data.appending(path: "tftp")
    if tftpRootIsAFile {
        try Data().write(to: tftp)
    } else {
        try FileManager.default.createDirectory(at: tftp, withIntermediateDirectories: true)
        for file in ["hwe-vmlinuz", "hwe-initrd"] { try Data("\(file)\n".utf8).write(to: tftp.appending(path: file)) }
    }

    let client = try await PXETestClient()
    let destination = client.address
    let service = PXEService(settings: PXESettings(interface: interface), tftpRoot: tftp, provisioner: provisioner,
                             logger: testLogger, retry: retry) { configuration in
        (configuration.dhcpPort, configuration.pxePort, configuration.tftpPort) = (0, 0, 0)
        configuration.offerDestination = destination
        configure(&configuration)
    }
    let group = ServiceGroup(configuration: .init(services: [service], logger: testLogger))
    let running = Task { try await group.run() }
    do {
        try await body(service, provisioner, client)
    } catch {
        await group.triggerGracefulShutdown()
        _ = try? await running.value
        await client.close()
        throw error
    }
    await group.triggerGracefulShutdown()
    let ended = TestFlag()
    let finishing = Task {
        defer { ended.set() }
        try await running.value
    }
    try await poll(within: .seconds(2)) { ended.isSet }
    #expect(ended.isSet, "the service group didn't end within 2 s of graceful shutdown")
    if ended.isSet { try await finishing.value }
    #expect(service.state == .down)
    #expect(service.boundPorts == nil)
    await client.close()
}

/// Waits until the service has tried to start at least twice: it failed, and retried.
private func waitForRetry(_ service: PXEService) async throws {
    try await poll(within: .seconds(2)) { service.startAttempts >= 2 }
    #expect(service.startAttempts >= 2, "no retry after a failed start")
}

private func waitUntilUp(_ service: PXEService) async throws -> (dhcp: Int, pxe: Int, tftp: Int) {
    try await poll(within: .seconds(2)) { service.boundPorts != nil }
    return try #require(service.boundPorts, "PXE never started")
}

@Test func pxeEventsMapToObservations() throws {
    let mac = try #require(MACAddress(bytes: boundMAC))
    #expect(PXEObservation(.offered(PXEClient(mac: mac, architecture: 7, uuid: nil))) == .offered(mac: "aa:bb:cc:00:00:01"))
    #expect(PXEObservation(.fileSent(TFTPDelivery(filename: "hwe-initrd", clientAddress: "10.0.0.5", mac: mac, bytes: 3)))
        == .fileSent(filename: "hwe-initrd", mac: "aa:bb:cc:00:00:01"))
    #expect(PXEObservation(.fileSent(TFTPDelivery(filename: "grubx64.efi", clientAddress: "10.0.0.5", mac: nil, bytes: 3)))
        == .fileSent(filename: "grubx64.efi", mac: nil))
}

@Test func servedOfferAndFilesReachTheQueue() async throws {
    try await withPXEService { service, provisioner, client in
        let ports = try await waitUntilUp(service)
        #expect(service.state == .up)

        try await client.dhcp(messageType: 1, port: ports.dhcp)
        let offer = try #require(await client.receive(), "no offer")
        #expect(DHCPPacket(buffer: offer.data)?.file == "grubx64.efi")
        try await client.dhcp(messageType: 3, port: ports.dhcp)
        for file in ["hwe-vmlinuz", "hwe-initrd"] {
            guard case .data = try await client.read(file, port: ports.tftp) else {
                Issue.record("no data for \(file)")
                return
            }
        }

        try await poll(within: .seconds(2)) { await eventSummary(provisioner).contains("step-reached m-1 booting") }
        #expect(await eventSummary(provisioner) == ["step-reached m-1 found", "step-reached m-1 booting"])
    }
}

/// `services` from `/api/v1/status`.
private func statusServices(_ client: any TestClientProtocol) async throws -> [String: String] {
    let response = try await client.execute(uri: "/api/v1/status", method: .get)
    let status = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
    return try #require(status?["services"] as? [String: String])
}

/// `services` from the status of an app reporting `service`.
private func statusServices(_ service: PXEService, _ provisioner: Provisioner) async throws -> [String: String] {
    let configuration = ServerConfiguration(port: 0, bind: "127.0.0.1", files: try temporaryDirectory(),
                                            dataDirectory: try temporaryDirectory())
    let app = try buildApplication(configuration, provisioner: provisioner, logger: testLogger,
                                   pxeState: { service.state })
    return try await app.test(.router) { client in try await statusServices(client) }
}

@Test func statusReportsNetboot() async throws {
    try await withPXEService { service, provisioner, _ in
        _ = try await waitUntilUp(service)
        let services = try await statusServices(service, provisioner)
        #expect(services == ["http": "up", "netboot": "up"])
    }
}

@Test func statusOmitsNetbootWithoutPXE() async throws {
    try await withLiveServer { _, client, _ in
        let services = try await statusServices(client)
        #expect(services == ["http": "up"])
    }
}

@Test func pxeOnMissingInterfaceReportsDown() async throws {
    try await withPXEService(interface: "nope0", retry: .milliseconds(20)) { service, provisioner, _ in
        try await waitForRetry(service)
        let services = try await statusServices(service, provisioner)
        #expect(services == ["http": "up", "netboot": "down"])
    }
}

/// A TFTP root that can't be created is a failed start like any other: retried, HTTP unaffected.
@Test func unusableTFTPRootRetriesWithoutStoppingTheServer() async throws {
    try await withPXEService(retry: .milliseconds(20), tftpRootIsAFile: true) { service, _, _ in
        try await waitForRetry(service)
        #expect(service.state == .down)
    }
}

@Test func pxeRetriesUntilThePortIsFree() async throws {
    let occupant = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "0.0.0.0", port: 0).get()
    let held = occupant.localAddress!.port!
    try await withPXEService(retry: .milliseconds(20), configure: { $0.tftpPort = held }) { service, _, _ in
        try await waitForRetry(service)
        #expect(service.state == .down)

        try await occupant.close()
        _ = try await waitUntilUp(service)
        #expect(service.state == .up)
    }
}

@Test func shutdownDuringRetryEnds() async throws {
    let started = ContinuousClock.now
    try await withPXEService(interface: "nope0", retry: .seconds(60)) { _, _, _ in
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(ContinuousClock.now - started < .seconds(1))
}
#endif
