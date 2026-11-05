import Foundation
import Logging
import ServiceLifecycle

/// `provisioner-server`'s entry point: parse flags, open the store, serve until
/// SIGTERM or SIGINT. Returns the process exit status.
public enum ServerMain {
    public static func run(arguments: [String]) async -> Int32 {
        let logger = Logger(label: "provisioner-server")
        let configuration: ServerConfiguration
        do {
            configuration = try ServerConfiguration.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\(ServerConfiguration.usage)\n".utf8))
            return 64
        }
        do {
            let provisioner = try Provisioner(dataDirectory: DataDirectory(configuration.dataDirectory), logger: logger)
            let app = try buildApplication(configuration, provisioner: provisioner, logger: logger)
            logger.info("serving \(configuration.files.path) on \(configuration.bind):\(configuration.port), data in \(configuration.dataDirectory.path)")
            let group = ServiceGroup(configuration: .init(services: [app], gracefulShutdownSignals: [.sigterm, .sigint],
                                                          logger: logger))
            try await group.run()
            return 0
        } catch {
            logger.critical("provisioner-server stopped: \(error)")
            return 1
        }
    }
}
