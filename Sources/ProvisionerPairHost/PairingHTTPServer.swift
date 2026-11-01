import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ProvisionerKit

/// Serves one `PairingHost` over HTTP/1.1:
/// `POST /pair/hello`, `/pair/reveal`, `/pair/key` (held open until the key is released or the
/// session ends), `/pair/result`, `/pair/cancel`, each with a JSON body.
public final class PairingHTTPServer: Sendable {
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup

    public var port: Int { channel.localAddress?.port ?? 0 }

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup) {
        self.channel = channel
        self.group = group
    }

    /// Binds a random port on `bindHost`.
    public static func start(host: PairingHost, bindHost: String = "127.0.0.1") async throws -> PairingHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(PairingHTTPHandler(host: host))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: bindHost, port: 0).get()
            return PairingHTTPServer(channel: channel, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

private final class PairingHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let host: PairingHost
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false
    /// Pairing messages are a few hundred bytes.
    static let maxBodyBytes = 64 * 1024

    init(host: PairingHost) { self.host = host }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
            tooLarge = false
        case .body(var chunk):
            if body.readableBytes + chunk.readableBytes > Self.maxBodyBytes {
                tooLarge = true
                body.clear()
            }
            if !tooLarge { body.writeBuffer(&chunk) }
        case .end:
            guard let head else { return }
            if tooLarge {
                respond(context: context, status: .payloadTooLarge, body: Data(), keepAlive: false)
                return
            }
            let path = head.uri
            let method = head.method
            let bytes = Data(body.readableBytesView)
            let keepAlive = head.isKeepAlive
            let loop = context.eventLoop
            let bound = NIOLoopBound((self, context), eventLoop: loop)
            Task { [host] in
                let (status, response) = await Self.route(host: host, method: method, path: path, body: bytes)
                loop.execute {
                    let (handler, context) = bound.value
                    handler.respond(context: context, status: status, body: response, keepAlive: keepAlive)
                }
            }
        }
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(body.count))
        headers.add(name: "connection", value: keepAlive ? "keep-alive" : "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        let channel = context.channel
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive { done.whenComplete { _ in channel.close(promise: nil) } }
    }

    static func route(host: PairingHost, method: HTTPMethod, path: String, body: Data) async -> (HTTPResponseStatus, Data) {
        guard method == .POST else { return (.notFound, Data()) }
        do {
            switch path {
            case "/pair/hello":
                return (.ok, try encode(await host.hello(decode(PairingHello.self, body))))
            case "/pair/reveal":
                try await host.reveal(decode(PairingReveal.self, body))
                return (.noContent, Data())
            case "/pair/key":
                return (.ok, try encode(await host.awaitKey(decode(PairingSessionRequest.self, body))))
            case "/pair/result":
                try await host.report(decode(PairingResult.self, body))
                return (.noContent, Data())
            case "/pair/cancel":
                try await host.appCancel(decode(PairingSessionRequest.self, body))
                return (.noContent, Data())
            default:
                return (.notFound, Data())
            }
        } catch let error as PairingHostError {
            return (status(for: error), Data())
        } catch {
            return (.badRequest, Data())
        }
    }

    static func status(for error: PairingHostError) -> HTTPResponseStatus {
        switch error {
        case .wrongNonce: .notFound
        case .alreadyConnected: .conflict
        case .unknownSession, .commitmentMismatch: .forbidden
        case .cancelled, .finished: .gone
        case .timedOut: .requestTimeout
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }
}
