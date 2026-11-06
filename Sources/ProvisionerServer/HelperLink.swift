#if canImport(ProvisionerHelperXPC)
import Logging
import ProvisionerHelperXPC

extension PXEObservation {
    init?(_ event: HelperEvent) {
        switch event {
        case .offered(let mac, _, _): self = .offered(mac: mac)
        case .fileSent(let filename, _, let mac, _): self = .fileSent(filename: filename, mac: mac)
        }
    }
}

/// Records every event the helper sends while registering with it every `retry`,
/// so a client whose connection was invalidated, by a helper that was replaced or
/// registered again, connects afresh. Returns when `client.events` finishes, which
/// `client.invalidate()` does, or when cancelled.
func linkHelper(_ client: HelperClient, to provisioner: Provisioner, logger: Logger,
                retry: Duration = .seconds(30)) async {
    await withDiscardingTaskGroup { group in
        group.addTask { await keepRegistered(client, logger: logger, every: retry) }
        for await event in client.events {
            if let observation = PXEObservation(event) { await provisioner.observe(observation) }
        }
        group.cancelAll()
    }
}

private func keepRegistered(_ client: HelperClient, logger: Logger, every retry: Duration) async {
    var failing = false
    while !Task.isCancelled {
        do {
            _ = try await client.servingInterface()
            if failing { logger.info("registered with the helper") }
            failing = false
        } catch HelperError.invalidated {
            return
        } catch {
            logger.warning("registering with the helper failed, retrying in \(retry): \(error)")
            failing = true
        }
        do { try await Task.sleep(for: retry) } catch { return }
    }
}

/// Starts `linkHelper` when the configuration asks for it. The returned closure
/// cancels the link, invalidates its client and waits for it to end.
func startHelperLink(_ configuration: ServerConfiguration, provisioner: Provisioner,
                     logger: Logger) -> @Sendable () async -> Void {
    guard configuration.linksHelper else { return {} }
    let client = HelperClient()
    let link = Task { await linkHelper(client, to: provisioner, logger: logger) }
    return {
        link.cancel()
        client.invalidate()
        await link.value
    }
}
#else
import Logging

func startHelperLink(_ configuration: ServerConfiguration, provisioner: Provisioner,
                     logger: Logger) -> @Sendable () async -> Void {
    {}
}
#endif
