import Foundation
import Logging
import ProvisionerAPI
import ProvisionerLog
import ServiceLifecycle

/// `provisioner-server`'s entry point: parse flags, open the store, serve until
/// SIGTERM or SIGINT. Returns the process exit status.
public enum ServerMain {
    /// Routes the process's logging to the platform's log; the executable calls it once, before `run`.
    public static func bootstrapLogging() { ProvisionerLog.bootstrap() }

    /// `makeLogger` makes each category's logger; tests capture them.
    public static func run(arguments: [String],
                           makeLogger: (String) -> Logger = { Logger(label: $0) }) async -> Int32 {
        let lifecycle = makeLogger(ServerLifecycle.category)
        lifecycle.notice("\(ServerLifecycle.launched)")
        let configuration: ServerConfiguration
        do {
            configuration = try ServerConfiguration.parse(arguments).readingPXESettingsFile()
        } catch {
            lifecycle.critical("\(ServerLifecycle.stoppedPrefix)\(error)")
            // A terminal already shows the logged error, through the log's stderr echo.
            let echoed = isatty(STDERR_FILENO) != 0
            FileHandle.standardError.write(Data("\(echoed ? "" : "\(error)\n")\(ServerConfiguration.usage)\n".utf8))
            return 64
        }
        do {
            let logger = makeLogger("provisioner")
            let bootImage = try configuration.bootImage.map { try BootImage(files: configuration.files, path: $0) }
            let provisioner = try Provisioner(dataDirectory: DataDirectory(configuration.dataDirectory),
                                              bootImage: bootImage, logger: logger)
            let pxe = configuration.pxe.map {
                PXEService(settings: $0, tftpRoot: configuration.tftpRoot, provisioner: provisioner,
                           logger: makeLogger("pxe"))
            }
            var pxeState: (@Sendable () -> Components.Schemas.ServiceState)?
            if let pxe { pxeState = { pxe.state } }
            let app = try buildApplication(configuration, provisioner: provisioner, logger: makeLogger("http"),
                                           pxeState: pxeState)
            lifecycle.info("serving \(configuration.files.path) on \(configuration.bind):\(configuration.port), data in \(configuration.dataDirectory.path)")
            if pxe == nil { lifecycle.info("serving no PXE: no --pxe-interface and no \(ServerConfiguration.settingsFile(in: configuration.dataDirectory).path)") }
            let advertising = makeLogger("advertisement")
            let advertisement = Advertisement(record: ServiceRecord(hostName: localHostName(), port: configuration.port),
                                              publisher: platformPublisher(logger: advertising), logger: advertising)
            let services: [any Service] = [app, advertisement] + (pxe.map { [$0] } ?? [])
            let group = ServiceGroup(configuration: .init(services: services, gracefulShutdownSignals: [.sigterm, .sigint],
                                                          logger: lifecycle))
            try await group.run()
            lifecycle.notice("stopped")
            return 0
        } catch {
            lifecycle.critical("\(ServerLifecycle.stoppedPrefix)\(error)")
            return 1
        }
    }
}
