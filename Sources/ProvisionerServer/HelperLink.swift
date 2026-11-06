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

/// Registers with the helper, retrying every `retry` until it answers, then records
/// every event it sends. Returns when `client.events` finishes.
func linkHelper(_ client: HelperClient, to provisioner: Provisioner, logger: Logger,
                retry: Duration = .seconds(30)) async {
    while true {
        do {
            _ = try await client.servingInterface()
            break
        } catch {
            logger.warning("registering with the helper failed, retrying in \(retry): \(error)")
            do { try await Task.sleep(for: retry) } catch { return }
        }
    }
    for await event in client.events {
        if let observation = PXEObservation(event) { await provisioner.observe(observation) }
    }
}
#endif
