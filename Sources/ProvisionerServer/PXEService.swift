import Foundation
import Logging
import NIOConcurrencyHelpers
import ProvisionerAPI
import ProvisionerPXE
import ServiceLifecycle

extension PXEObservation {
    /// nil for an offer that failed, which tells the provisioner nothing about the machine.
    init?(_ event: PXEEvent) {
        switch event {
        case .offered(let client): self = .offered(mac: client.mac.description)
        case .offerFailed: return nil
        case .fileSent(let delivery): self = .fileSent(filename: delivery.filename, mac: delivery.mac?.description)
        }
    }
}

/// Serves proxy DHCP and TFTP on one interface and records each PXE event in the provisioner.
/// A start that fails leaves the service down and is retried every `retry` until graceful shutdown.
final class PXEService: Service, Sendable {
    private let settings: PXESettings
    private let tftpRoot: URL
    private let provisioner: Provisioner
    private let logger: Logger
    private let retry: Duration
    private let configure: @Sendable (inout PXEConfiguration) -> Void
    private let serving = NIOLockedValueBox<PXEServer?>(nil)
    private let attempts = NIOLockedValueBox(0)

    init(settings: PXESettings, tftpRoot: URL, provisioner: Provisioner, logger: Logger,
         retry: Duration = .seconds(30), configure: @escaping @Sendable (inout PXEConfiguration) -> Void = { _ in }) {
        self.settings = settings
        self.tftpRoot = tftpRoot
        self.provisioner = provisioner
        self.logger = logger
        self.retry = retry
        self.configure = configure
    }

    var state: Components.Schemas.ServiceState { serving.withLockedValue { $0 } == nil ? .down : .up }

    /// The ports the running server bound, or nil while it isn't running.
    var boundPorts: (dhcp: Int, pxe: Int, tftp: Int)? { serving.withLockedValue { $0 }?.boundPorts }

    /// How many times `run()` has tried to start serving.
    var startAttempts: Int { attempts.withLockedValue { $0 } }

    func run() async throws {
        var failed = false
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            let server = PXEServer(configuration: pxeConfiguration())
            attempts.withLockedValue { $0 += 1 }
            do {
                try FileManager.default.createDirectory(at: tftpRoot, withIntermediateDirectories: true)
                try await server.start()
            } catch {
                logger.error("PXE on \(settings.interface) failed to start, retrying in \(retry): \(error)")
                failed = true
                try? await cancelWhenGracefulShutdown { try await Task.sleep(for: self.retry) }
                continue
            }
            logger.info("\(failed ? "recovered: " : "")serving PXE on \(settings.interface) with \(settings.bootFile), TFTP from \(tftpRoot.path)")
            serving.withLockedValue { $0 = server }
            await withTaskCancellationHandler {
                await withGracefulShutdownHandler {
                    await pump(server.events)
                } onGracefulShutdown: {
                    Task { await server.stop() }
                }
            } onCancel: {
                Task { await server.stop() }
            }
            serving.withLockedValue { $0 = nil }
            return
        }
    }

    private func pxeConfiguration() -> PXEConfiguration {
        var configuration = PXEConfiguration(interface: settings.interface, tftpRoot: tftpRoot)
        configuration.bootFilename = settings.bootFile
        configure(&configuration)
        return configuration
    }

    private func pump(_ events: AsyncStream<PXEEvent>) async {
        for await event in events {
            switch event {
            case .offered(let client):
                logger.info("PXE offer to \(client.mac) arch \(client.architecture)")
            case .offerFailed(let failure):
                logger.error("PXE offer to \(failure.mac) failed: sending to \(failure.destination) on \(failure.interface): \(failure.error)")
            case .fileSent(let delivery):
                logger.info("TFTP sent \(delivery.filename) to \(delivery.clientAddress) mac \(delivery.mac.map(String.init(describing:)) ?? "-"), \(delivery.bytes) bytes")
            }
            if let observation = PXEObservation(event) {
                await provisioner.observe(observation)
            }
        }
    }
}
