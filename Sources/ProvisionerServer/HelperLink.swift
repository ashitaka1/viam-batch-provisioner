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
    while !Task.isCancelled {
        do {
            _ = try await client.servingInterface()
            break
        } catch {
            if case HelperError.connection("invalidated") = error { return }
            logger.warning("registering with the helper failed, retrying in \(retry): \(error)")
            do { try await Task.sleep(for: retry) } catch { return }
        }
    }
    for await event in client.events {
        if let observation = PXEObservation(event) { await provisioner.observe(observation) }
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
