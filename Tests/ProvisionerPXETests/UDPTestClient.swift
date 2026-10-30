import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import ProvisionerPXE

/// A FIFO that a synchronous producer fills and an async consumer drains with a deadline.
final class Inbox<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var waiter: (id: Int, continuation: CheckedContinuation<Element?, Never>)?
        var nextID = 0
    }

    private let state = NIOLockedValueBox(State())

    func push(_ element: Element) {
        let waiter = state.withLockedValue { state -> CheckedContinuation<Element?, Never>? in
            guard let waiter = state.waiter else {
                state.items.append(element)
                return nil
            }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume(returning: element)
    }

    /// The next element, or nil when none arrives within `timeout`.
    func next(timeout: Duration = .seconds(2)) async -> Element? {
        await withCheckedContinuation { continuation in
            let id = state.withLockedValue { state -> Int? in
                if !state.items.isEmpty {
                    continuation.resume(returning: state.items.removeFirst())
                    return nil
                }
                state.nextID += 1
                state.waiter = (state.nextID, continuation)
                return state.nextID
            }
            guard let id else { return }
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        let waiter = state.withLockedValue { state -> CheckedContinuation<Element?, Never>? in
            guard let waiter = state.waiter, waiter.id == id else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume(returning: nil)
    }
}

private final class InboxHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let inbox: Inbox<AddressedEnvelope<ByteBuffer>>

    init(inbox: Inbox<AddressedEnvelope<ByteBuffer>>) {
        self.inbox = inbox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        inbox.push(unwrapInboundIn(data))
    }
}

struct TFTPClientError: Error, CustomStringConvertible {
    let code: UInt16
    let message: String
    var description: String { "TFTP error \(code): \(message)" }
}

/// The PXE client side of the loopback tests: a UDP socket on 127.0.0.1.
final class UDPTestClient: Sendable {
    let channel: Channel
    let inbox = Inbox<AddressedEnvelope<ByteBuffer>>()
    private let duplicates = NIOLockedValueBox(0)

    /// DATA blocks the last `fetch` received more than once.
    var duplicateBlocks: Int { duplicates.withLockedValue { $0 } }

    var port: Int { channel.localAddress!.port! }
    var address: SocketAddress { channel.localAddress! }

    init() async throws {
        let inbox = inbox
        channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 65536))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(InboxHandler(inbox: inbox))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func close() async {
        try? await channel.close()
    }

    func send(_ buffer: ByteBuffer, to port: Int) async throws {
        try await send(buffer, to: SocketAddress(ipAddress: "127.0.0.1", port: port))
    }

    func send(_ buffer: ByteBuffer, to address: SocketAddress) async throws {
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer))
    }

    func receive(timeout: Duration = .seconds(2)) async -> AddressedEnvelope<ByteBuffer>? {
        await inbox.next(timeout: timeout)
    }

    /// Reads a file over TFTP: RRQ, OACK → ACK 0, ACK each DATA, stop on a short block.
    func fetch(_ filename: String, options: [TFTPOption] = [], port: Int) async throws -> Data {
        duplicates.withLockedValue { $0 = 0 }
        try await send(TFTPPacket.readRequest(filename: filename, mode: "octet", options: options).encoded(), to: port)
        var blockSize = 512
        var received = Data()
        var expected: UInt16 = 1
        while true {
            guard let envelope = await receive() else { throw TFTPClientError(code: 0, message: "timed out") }
            guard let packet = TFTPPacket(buffer: envelope.data) else { continue }
            switch packet {
            case let .optionAck(acknowledged):
                if let size = acknowledged.first(where: { $0.name == "blksize" }) {
                    blockSize = Int(size.value)!
                }
                try await send(TFTPPacket.ack(block: 0).encoded(), to: envelope.remoteAddress)
            case let .data(block, payload):
                try await send(TFTPPacket.ack(block: block).encoded(), to: envelope.remoteAddress)
                guard block == expected else {
                    duplicates.withLockedValue { $0 += 1 }
                    continue
                }
                expected &+= 1
                received.append(contentsOf: payload.readableBytesView)
                if payload.readableBytes < blockSize { return received }
            case let .error(code, message):
                throw TFTPClientError(code: code, message: message)
            default:
                continue
            }
        }
    }
}
