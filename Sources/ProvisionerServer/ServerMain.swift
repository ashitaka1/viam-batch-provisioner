import Foundation
import Logging
import ProvisionerAPI
import ServiceLifecycle

/// `provisioner-server`'s entry point: parse flags, open the store, serve until
/// SIGTERM or SIGINT. Returns the process exit status.
public enum ServerMain {
    public static func run(arguments: [String]) async -> Int32 {
        let logger = Logger(label: "provisioner-server")
        let configuration: ServerConfiguration
        do {
            configuration = try ServerConfiguration.parse(arguments).readingPXESettingsFile()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\(ServerConfiguration.usage)\n".utf8))
            return 64
        }
        do {
            let bootImage = try configuration.bootImage.map { try BootImage(files: configuration.files, path: $0) }
            let provisioner = try Provisioner(dataDirectory: DataDirectory(configuration.dataDirectory),
                                              bootImage: bootImage, logger: logger)
            let pxe = configuration.pxe.map {
                PXEService(settings: $0, tftpRoot: configuration.tftpRoot, provisioner: provisioner, logger: logger)
            }
            var pxeState: (@Sendable () -> Components.Schemas.ServiceState)?
            if let pxe { pxeState = { pxe.state } }
            let app = try buildApplication(configuration, provisioner: provisioner, logger: logger, pxeState: pxeState)
            logger.info("serving \(configuration.files.path) on \(configuration.bind):\(configuration.port), data in \(configuration.dataDirectory.path)")
            if pxe == nil { logger.info("serving no PXE: no --pxe-interface and no \(ServerConfiguration.settingsFile(in: configuration.dataDirectory).path)") }
            let advertisement = Advertisement(record: ServiceRecord(hostName: localHostName(), port: configuration.port),
                                              publisher: platformPublisher(logger: logger), logger: logger)
            let services: [any Service] = [app, advertisement] + (pxe.map { [$0] } ?? [])
            let group = ServiceGroup(configuration: .init(services: services, gracefulShutdownSignals: [.sigterm, .sigint],
                                                          logger: logger))
            try await group.run()
            return 0
        } catch {
            logger.critical("provisioner-server stopped: \(error)")
            return 1
        }
    }
}
