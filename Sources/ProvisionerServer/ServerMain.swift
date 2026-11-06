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
            let bootImage = try configuration.bootImage.map { try BootImage(files: configuration.files, path: $0) }
            let provisioner = try Provisioner(dataDirectory: DataDirectory(configuration.dataDirectory),
                                              bootImage: bootImage, logger: logger)
            let app = try buildApplication(configuration, provisioner: provisioner, logger: logger)
            logger.info("serving \(configuration.files.path) on \(configuration.bind):\(configuration.port), data in \(configuration.dataDirectory.path)")
            let group = ServiceGroup(configuration: .init(services: [app], gracefulShutdownSignals: [.sigterm, .sigint],
                                                          logger: logger))
            let stopLink = startHelperLink(configuration, provisioner: provisioner, logger: logger)
            do {
                try await group.run()
            } catch {
                await stopLink()
                throw error
            }
            await stopLink()
            return 0
        } catch {
            logger.critical("provisioner-server stopped: \(error)")
            return 1
        }
    }
}
