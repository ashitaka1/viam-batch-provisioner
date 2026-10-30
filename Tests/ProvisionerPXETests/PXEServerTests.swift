import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import ProvisionerPXE

private func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<(count + 7) / 8).flatMap { _ in withUnsafeBytes(of: generator.next()) { Array($0) } }.prefix(count))
}

/// A server on lo0 with ephemeral ports, offering to a test client, serving `base/root`.
/// `base/secret.txt` sits outside the root.
private final class Harness: Sendable {
    let base: URL
    let root: URL
    let client: UDPTestClient
    let server: PXEServer
    let reported = Inbox<PXEClient>()
    /// Receives one element when the `clients` stream finishes.
    let clientsFinished = Inbox<Void>()
    let ports: (dhcp: Int, pxe: Int, tftp: Int)
    let kernel = randomData(100_000)
    let bootloader = randomData(4096)

    init(tftpTimeout: TimeAmount) async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("grub"), withIntermediateDirectories: true)
        try bootloader.write(to: root.appendingPathComponent("grubx64.efi"))
        try kernel.write(to: root.appendingPathComponent("vmlinuz"))
        try Data("secret\n".utf8).write(to: base.appendingPathComponent("secret.txt"))

        client = try await UDPTestClient()
        var configuration = PXEConfiguration(interface: "lo0", tftpRoot: root)
        configuration.dhcpPort = 0
        configuration.pxePort = 0
        configuration.tftpPort = 0
        configuration.offerDestination = client.address
        configuration.tftpTimeout = tftpTimeout
        server = PXEServer(configuration: configuration)
        try await server.start()
        ports = server.boundPorts!

        let reported = reported
        let clientsFinished = clientsFinished
        let clients = server.clients
        Task {
            for await pxeClient in clients { reported.push(pxeClient) }
            clientsFinished.push(())
        }
    }

    func shutdown() async {
        try? await server.stop()
        await client.close()
        try? FileManager.default.removeItem(at: base)
    }
}

/// Runs `body` against a fresh harness and shuts it down whether or not `body` throws.
private func withHarness(
    tftpTimeout: TimeAmount = .seconds(1),
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try await Harness(tftpTimeout: tftpTimeout)
    do {
        try await body(harness)
    } catch {
        await harness.shutdown()
        throw error
    }
    await harness.shutdown()
}

private func readRequest(_ filename: String, options: [TFTPOption] = []) -> ByteBuffer {
    TFTPPacket.readRequest(filename: filename, mode: "octet", options: options).encoded()
}

@Suite struct PXEServerTests {
    @Test func offersOverLoopback() async throws {
        try await withHarness { harness in
            try await harness.client.send(pxeDiscover().encoded(), to: harness.ports.dhcp)

            let envelope = try #require(await harness.client.receive(), "no offer")
            let offer = try #require(DHCPPacket(buffer: envelope.data))
            #expect(offer.messageType == 2)
            #expect(offer.file == "grubx64.efi")
            #expect(offer.siaddr == 0x7F00_0001)
            #expect(await harness.reported.next() == PXEClient(mac: MACAddress(bytes: fixtureMAC)!, architecture: 7, uuid: fixtureUUID))
        }
    }

    @Test func acksOnPXEPort() async throws {
        try await withHarness { harness in
            try await harness.client.send(pxeDiscover(messageType: 3).encoded(), to: harness.ports.pxe)

            let envelope = try #require(await harness.client.receive(), "no ack")
            #expect(DHCPPacket(buffer: envelope.data)?.messageType == 5)
            #expect(await harness.reported.next(timeout: .milliseconds(200)) == nil, "a 4011 request was reported")
        }
    }

    @Test func ignoresGarbage() async throws {
        try await withHarness { harness in
            var garbage = ByteBuffer()
            garbage.writeBytes(randomData(50))
            try await harness.client.send(garbage, to: harness.ports.dhcp)
            try await harness.client.send(pxeDiscover(vendorClass: nil).encoded(), to: harness.ports.dhcp)
            try await harness.client.send(pxeDiscover().encoded(), to: harness.ports.dhcp)

            let first = try #require(await harness.client.receive(), "no reply at all")
            #expect(DHCPPacket(buffer: first.data)?.messageType == 2, "first reply was not the offer to the valid discover")
            #expect(await harness.client.receive(timeout: .milliseconds(200)) == nil, "answered garbage or non-PXE DHCP")
            #expect(await harness.reported.next()?.mac == MACAddress(bytes: fixtureMAC))
            #expect(await harness.reported.next(timeout: .milliseconds(100)) == nil)
        }
    }

    @Test func fetchesWithOptions() async throws {
        try await withHarness { harness in
            let options = [TFTPOption(name: "blksize", value: "1468"), TFTPOption(name: "tsize", value: "0")]
            let data = try await harness.client.fetch("vmlinuz", options: options, port: harness.ports.tftp)
            #expect(data == harness.kernel, "got \(data.count) of \(harness.kernel.count) bytes")
        }
    }

    @Test func fetchesWithoutOptions() async throws {
        try await withHarness { harness in
            let data = try await harness.client.fetch("grubx64.efi", port: harness.ports.tftp)
            #expect(data == harness.bootloader)
            #expect(harness.client.duplicateBlocks == 0, "server resent \(harness.client.duplicateBlocks) blocks that were acknowledged")
        }
    }

    @Test func guardAppearsLive() async throws {
        try await withHarness { harness in
            let guardName = "grub/provisioned/aa:bb:cc:dd:ee:ff.cfg"
            do {
                _ = try await harness.client.fetch(guardName, port: harness.ports.tftp)
                Issue.record("served a guard that does not exist")
            } catch let error as TFTPClientError {
                #expect(error.code == 1, "\(error)")
            }

            let guardURL = harness.root.appendingPathComponent(guardName)
            try FileManager.default.createDirectory(at: guardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("exit\n".utf8).write(to: guardURL)
            let data = try await harness.client.fetch(guardName, port: harness.ports.tftp)
            #expect(String(decoding: data, as: UTF8.self) == "exit\n")
        }
    }

    @Test func refusesFilesOutsideRoot() async throws {
        try await withHarness { harness in
            do {
                let data = try await harness.client.fetch("../secret.txt", port: harness.ports.tftp)
                Issue.record("served \(String(decoding: data, as: UTF8.self)) from outside the root")
            } catch let error as TFTPClientError {
                #expect(error.code == 1, "\(error)")
            }
        }
    }

    @Test func refusesWrites() async throws {
        try await withHarness { harness in
            try await harness.client.send(TFTPPacket.writeRequest(filename: "x", mode: "octet").encoded(), to: harness.ports.tftp)
            let reply = try #require(await harness.client.receive())
            guard case .error(code: 4, _) = TFTPPacket(buffer: reply.data) else {
                Issue.record("expected ERROR 4, got \(String(describing: TFTPPacket(buffer: reply.data)))")
                return
            }
        }
    }

    @Test func concurrentTransfers() async throws {
        try await withHarness { harness in
            let port = harness.ports.tftp
            let results = try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        let client = try await UDPTestClient()
                        let result = await Result {
                            try await client.fetch("vmlinuz", options: [TFTPOption(name: "blksize", value: "1468")], port: port)
                        }
                        await client.close()
                        return try result.get()
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.count == 4)
            for data in results {
                #expect(data == harness.kernel, "got \(data.count) of \(harness.kernel.count) bytes")
            }
        }
    }

    @Test func rejectsForeignTransferID() async throws {
        try await withHarness { harness in
            try await harness.client.send(readRequest("grubx64.efi"), to: harness.ports.tftp)
            let first = try #require(await harness.client.receive())
            guard case .data(block: 1, _) = TFTPPacket(buffer: first.data) else {
                Issue.record("first reply was not DATA 1")
                return
            }

            let stranger = try await UDPTestClient()
            try await stranger.send(TFTPPacket.ack(block: 1).encoded(), to: first.remoteAddress)
            let rejection = try #require(await stranger.receive(), "stranger got no reply")
            await stranger.close()
            guard case .error(code: 5, _) = TFTPPacket(buffer: rejection.data) else {
                Issue.record("stranger got \(String(describing: TFTPPacket(buffer: rejection.data))), expected ERROR 5")
                return
            }

            // The real client's next ACK continues from block 1: the stranger's ACK did not advance it.
            try await harness.client.send(TFTPPacket.ack(block: 1).encoded(), to: first.remoteAddress)
            var next = try #require(await harness.client.receive())
            while case .data(block: 1, _) = TFTPPacket(buffer: next.data) {
                next = try #require(await harness.client.receive())
            }
            guard case .data(block: 2, _) = TFTPPacket(buffer: next.data) else {
                Issue.record("after ACK 1 got \(String(describing: TFTPPacket(buffer: next.data))), expected DATA 2")
                return
            }
        }
    }

    @Test func retransmitsThenStops() async throws {
        try await withHarness(tftpTimeout: .milliseconds(100)) { harness in
            try await harness.client.send(readRequest("grubx64.efi"), to: harness.ports.tftp)
            var sends = 0
            while sends < 50, let envelope = await harness.client.receive(timeout: .seconds(1)) {
                if case .data(block: 1, _) = TFTPPacket(buffer: envelope.data) { sends += 1 }
            }
            #expect(sends >= 2, "block 1 was never resent")
            #expect(sends < 50, "the server kept resending an unacknowledged block")
        }
    }

    @Test func clientErrorEndsTransfer() async throws {
        try await withHarness(tftpTimeout: .milliseconds(100)) { harness in
            try await harness.client.send(readRequest("grubx64.efi"), to: harness.ports.tftp)
            let first = try #require(await harness.client.receive())
            try await harness.client.send(TFTPPacket.error(code: 0, message: "abort").encoded(), to: first.remoteAddress)
            #expect(await harness.client.receive(timeout: .milliseconds(500)) == nil, "server kept sending after the client's ERROR")
        }
    }

    @Test func negotiatedTimeoutOverridesDefault() async throws {
        try await withHarness(tftpTimeout: .milliseconds(100)) { harness in
            try await harness.client.send(readRequest("grubx64.efi", options: [TFTPOption(name: "timeout", value: "1")]), to: harness.ports.tftp)
            let optionAck = try #require(await harness.client.receive())
            guard case .optionAck = TFTPPacket(buffer: optionAck.data) else {
                Issue.record("expected OACK")
                return
            }
            let sent = ContinuousClock.now
            _ = try #require(await harness.client.receive(), "OACK never resent")
            let elapsed = ContinuousClock.now - sent
            #expect(elapsed >= .milliseconds(900), "resent after \(elapsed), expected the negotiated 1 s")
        }
    }

    @Test func stopReleasesPortsAndFinishesClients() async throws {
        let harness = try await Harness(tftpTimeout: .seconds(1))
        let tftp = harness.ports.tftp
        try await harness.server.stop()

        #expect(await harness.clientsFinished.next() != nil, "clients stream still open after stop")
        let rebound = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: tftp)
            .get()
        try await rebound.close()
        await harness.shutdown()
    }

    @Test func unknownInterface() async throws {
        let server = PXEServer(configuration: PXEConfiguration(interface: "nope9", tftpRoot: URL(fileURLWithPath: "/tmp")))
        await #expect(throws: PXEServerError.interfaceNotFound("nope9")) {
            try await server.start()
        }
    }
}
