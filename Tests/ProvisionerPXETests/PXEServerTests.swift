import Foundation
import NIOCore
import Testing
@testable import ProvisionerPXE

/// A server on lo0 with ephemeral ports, offering to a test client, serving a temp directory.
private final class Harness: Sendable {
    let root: URL
    let client: UDPTestClient
    let server: PXEServer
    let reported = Inbox<PXEClient>()
    let ports: (dhcp: Int, pxe: Int, tftp: Int)
    let kernel: Data
    let bootloader: Data

    init(tftpTimeout: TimeAmount = .seconds(1)) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("grub"), withIntermediateDirectories: true)
        bootloader = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        kernel = Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) })
        try bootloader.write(to: root.appendingPathComponent("grubx64.efi"))
        try kernel.write(to: root.appendingPathComponent("vmlinuz"))
        try Data("set timeout=5\n".utf8).write(to: root.appendingPathComponent("grub/grub.cfg"))

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
        let clients = server.clients
        Task {
            for await pxeClient in clients { reported.push(pxeClient) }
        }
    }

    func shutdown() async throws {
        try await server.stop()
        await client.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct PXEServerTests {
    @Test func offersOverLoopback() async throws {
        let harness = try await Harness()
        try await harness.client.send(pxeDiscover().encoded(), to: harness.ports.dhcp)

        let envelope = try #require(await harness.client.receive(), "no offer")
        let offer = try #require(DHCPPacket(buffer: envelope.data))
        #expect(offer.messageType == 2)
        #expect(offer.file == "grubx64.efi")
        #expect(offer.siaddr == 0x7F00_0001)
        #expect(await harness.reported.next() == PXEClient(mac: MACAddress(bytes: fixtureMAC)!, architecture: 7, uuid: fixtureUUID))
        try await harness.shutdown()
    }

    @Test func acksOnPXEPort() async throws {
        let harness = try await Harness()
        try await harness.client.send(pxeDiscover(messageType: 3).encoded(), to: harness.ports.pxe)

        let envelope = try #require(await harness.client.receive(), "no ack")
        #expect(DHCPPacket(buffer: envelope.data)?.messageType == 5)
        #expect(await harness.reported.next(timeout: .milliseconds(200)) == nil, "a 4011 request was reported")
        try await harness.shutdown()
    }

    @Test func ignoresGarbage() async throws {
        let harness = try await Harness()
        try await harness.client.send(ByteBuffer(bytes: (0..<50).map { _ in UInt8.random(in: 0...255) }), to: harness.ports.dhcp)
        try await harness.client.send(pxeDiscover(vendorClass: nil).encoded(), to: harness.ports.dhcp)
        #expect(await harness.client.receive(timeout: .milliseconds(200)) == nil, "answered garbage or non-PXE DHCP")
        #expect(await harness.reported.next(timeout: .milliseconds(200)) == nil)

        try await harness.client.send(pxeDiscover().encoded(), to: harness.ports.dhcp)
        #expect(await harness.client.receive() != nil, "stopped answering after garbage")
        try await harness.shutdown()
    }

    @Test func fetchesWithOptions() async throws {
        let harness = try await Harness()
        let options = [TFTPOption(name: "blksize", value: "1468"), TFTPOption(name: "tsize", value: "0")]
        let data = try await harness.client.fetch("vmlinuz", options: options, port: harness.ports.tftp)
        #expect(data == harness.kernel, "got \(data.count) of \(harness.kernel.count) bytes")
        try await harness.shutdown()
    }

    @Test func fetchesWithoutOptions() async throws {
        let harness = try await Harness()
        let data = try await harness.client.fetch("grubx64.efi", port: harness.ports.tftp)
        #expect(data == harness.bootloader)
        try await harness.shutdown()
    }

    @Test func guardAppearsLive() async throws {
        let harness = try await Harness()
        let guardName = "grub/provisioned/aa:bb:cc:dd:ee:ff.cfg"
        await #expect(throws: TFTPClientError.self) {
            try await harness.client.fetch(guardName, port: harness.ports.tftp)
        }

        let guardURL = harness.root.appendingPathComponent(guardName)
        try FileManager.default.createDirectory(at: guardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exit\n".utf8).write(to: guardURL)
        let data = try await harness.client.fetch(guardName, port: harness.ports.tftp)
        #expect(String(decoding: data, as: UTF8.self) == "exit\n")
        try await harness.shutdown()
    }

    @Test func refusesTraversalAndWrites() async throws {
        let harness = try await Harness()
        do {
            _ = try await harness.client.fetch("../../etc/hosts", port: harness.ports.tftp)
            Issue.record("served a file outside the root")
        } catch let error as TFTPClientError {
            #expect(error.code == 1)
        }

        try await harness.client.send(TFTPPacket.writeRequest(filename: "x", mode: "octet").encoded(), to: harness.ports.tftp)
        let reply = try #require(await harness.client.receive())
        #expect(TFTPPacket(buffer: reply.data) == .error(code: 4, message: "Read-only server"))
        try await harness.shutdown()
    }

    @Test func concurrentTransfers() async throws {
        let harness = try await Harness()
        let port = harness.ports.tftp
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let client = try await UDPTestClient()
                    defer { Task { await client.close() } }
                    return try await client.fetch("vmlinuz", options: [TFTPOption(name: "blksize", value: "1468")], port: port)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 4)
        for data in results {
            #expect(data == harness.kernel, "got \(data.count) of \(harness.kernel.count) bytes")
        }
        try await harness.shutdown()
    }

    @Test func abandonedTransferCloses() async throws {
        let harness = try await Harness(tftpTimeout: .milliseconds(100))
        try await harness.client.send(
            TFTPPacket.readRequest(filename: "grubx64.efi", mode: "octet", options: []).encoded(),
            to: harness.ports.tftp
        )
        var sends = 0
        while let envelope = await harness.client.receive(timeout: .seconds(1)) {
            if case .data(block: 1, _) = TFTPPacket(buffer: envelope.data) { sends += 1 }
        }
        #expect(sends == 6, "block 1 sent \(sends) times, expected the first send plus 5 retries")
        try await harness.shutdown()
    }

    @Test func unknownInterface() async throws {
        let server = PXEServer(configuration: PXEConfiguration(interface: "nope9", tftpRoot: URL(fileURLWithPath: "/tmp")))
        await #expect(throws: PXEServerError.interfaceNotFound("nope9")) {
            try await server.start()
        }
    }
}
