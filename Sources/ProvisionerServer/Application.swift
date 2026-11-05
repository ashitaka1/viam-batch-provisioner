import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird

/// SSE settings; tests shorten the keepalive and lower the limits.
struct StreamOptions: Sendable {
    var keepalive: Duration = .seconds(15)
    var limit = 64
    /// Frames a stream holds for a client that isn't reading before it drops the client.
    var buffer = 256
}

func buildApplication(_ configuration: ServerConfiguration, provisioner: Provisioner, logger: Logger,
                      streamOptions: StreamOptions = .init()) throws -> some ApplicationProtocol {
    let router = Router()
    router.add(middleware: ErrorMiddleware(logger: logger))
    router.add(middleware: BodyLimitMiddleware())
    router.add(middleware: StaticFiles(root: configuration.files.path, logger: logger))
    let handler = APIHandler(provisioner: provisioner, configuration: configuration, streamOptions: streamOptions,
                             streams: StreamLimiter(limit: streamOptions.limit),
                             serverName: localHostName(), logger: logger)
    try handler.registerHandlers(on: router, serverURL: URL(string: "/")!)
    return Application(
        router: router,
        configuration: .init(address: .hostname(configuration.bind, port: configuration.port),
                             serverName: "provisioner-server"),
        logger: logger)
}

/// The kernel's host name. `ProcessInfo.hostName` can block on a reverse DNS lookup.
func localHostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
    return String(cString: buffer)
}
