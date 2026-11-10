#if canImport(ProvisionerNetbootXPC)
import Logging
import ProvisionerNetbootXPC

extension PXEObservation {
    init?(_ event: NetbootEvent) {
        switch event {
        case .offered(let mac, _, _): self = .offered(mac: mac)
        case .fileSent(let filename, _, let mac, _): self = .fileSent(filename: filename, mac: mac)
        }
    }
}

/// Records every event the netboot daemon sends while registering with it every `retry`,
/// so a client whose connection was invalidated, by a netboot daemon that was replaced or
/// registered again, connects afresh. Returns when `client.events` finishes, which
/// `client.invalidate()` does, or when cancelled.
func linkNetbootDaemon(_ client: NetbootClient, to provisioner: Provisioner, logger: Logger,
                retry: Duration = .seconds(30)) async {
    await withDiscardingTaskGroup { group in
        group.addTask { await keepRegistered(client, logger: logger, every: retry) }
        for await event in client.events {
            if let observation = PXEObservation(event) { await provisioner.observe(observation) }
        }
        group.cancelAll()
    }
}

private func keepRegistered(_ client: NetbootClient, logger: Logger, every retry: Duration) async {
    var failing = false
    while !Task.isCancelled {
        do {
            _ = try await client.servingInterface()
            if failing { logger.info("registered with the netboot daemon") }
            failing = false
        } catch NetbootError.invalidated {
            return
        } catch {
            logger.warning("registering with the netboot daemon failed, retrying in \(retry): \(error)")
            failing = true
        }
        do { try await Task.sleep(for: retry) } catch { return }
    }
}

/// Starts `linkNetbootDaemon` when the configuration asks for it. The returned closure
/// cancels the link, invalidates its client and waits for it to end.
func startNetbootLink(_ configuration: ServerConfiguration, provisioner: Provisioner,
                     logger: Logger) -> @Sendable () async -> Void {
    guard configuration.linksNetboot else { return {} }
    let client = NetbootClient()
    let link = Task { await linkNetbootDaemon(client, to: provisioner, logger: logger) }
    return {
        link.cancel()
        client.invalidate()
        await link.value
    }
}
#else
import Logging

func startNetbootLink(_ configuration: ServerConfiguration, provisioner: Provisioner,
                     logger: Logger) -> @Sendable () async -> Void {
    {}
}
#endif
