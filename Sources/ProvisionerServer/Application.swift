import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import ProvisionerAPI

/// SSE settings; tests shorten the keepalive and lower the limits.
struct StreamOptions: Sendable {
    var keepalive: Duration = .seconds(15)
    var limit = 64
    /// Frames a stream holds for a client that isn't reading before it drops the client.
    var buffer = 256
}

/// `pxeState` reports PXE serving in `/api/v1/status`; nil leaves it out, for a server that serves no PXE.
func buildApplication(_ configuration: ServerConfiguration, provisioner: Provisioner, logger: Logger,
                      streamOptions: StreamOptions = .init(),
                      pxeState: (@Sendable () -> Components.Schemas.ServiceState)? = nil) throws -> some ApplicationProtocol {
    let router = Router()
    router.add(middleware: RequestLogMiddleware(logger: logger))
    router.add(middleware: ErrorMiddleware(logger: logger))
    router.add(middleware: BodyLimitMiddleware())
    router.add(middleware: StaticFiles(root: configuration.files.path, logger: logger))
    let handler = APIHandler(provisioner: provisioner, configuration: configuration, streamOptions: streamOptions,
                             streams: StreamLimiter(limit: streamOptions.limit),
                             serverName: localHostName(), pxeState: pxeState, logger: logger)
    try handler.registerHandlers(on: router, serverURL: URL(string: "/")!)
    addImageRoute(to: router, provisioner: provisioner)
    addSeedRoute(to: router, provisioner: provisioner)
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
    let name = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: name, as: UTF8.self)
}
