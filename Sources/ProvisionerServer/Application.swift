import Foundation
import Hummingbird
import Logging

func buildApplication(_ configuration: ServerConfiguration, provisioner: Provisioner,
                      logger: Logger) throws -> some ApplicationProtocol {
    let router = Router()
    router.add(middleware: StaticFiles(root: configuration.files.path, logger: logger))
    return Application(
        router: router,
        configuration: .init(address: .hostname(configuration.bind, port: configuration.port),
                             serverName: "provisioner-server"),
        logger: logger)
}
