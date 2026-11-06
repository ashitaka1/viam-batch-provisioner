public import ProvisionerKit

/// How a pairing session ended: what to tell the operator, and whether the app stored the key.
public struct PairingEnd: Equatable, Sendable {
    public let message: String
    public let succeeded: Bool

    public init(message: String, succeeded: Bool) {
        self.message = message
        self.succeeded = succeeded
    }
}

/// What to tell the operator when the viam CLI fails.
public func pairingCLIMessage(_ error: any Error) -> String {
    switch error as? ViamCLIError {
    case .notInstalled: "Install the viam CLI: https://docs.viam.com/cli/"
    case .notLoggedIn: "Run 'viam login' first."
    case .failed(let stderr): "The viam CLI failed: \(stderr)"
    case .unparsableOrganizations: "Couldn't read the viam CLI's organization list. Update it with 'viam update'."
    case .unparsableKey, .tokenUnavailable, nil: "The viam CLI failed: \(error)"
    }
}

/// Where to delete a key the app may not have stored.
public func pairingDeleteHint(_ keyName: String) -> String {
    "Delete it in Viam: Organization → API keys → \"\(keyName)\"."
}

/// The command's half of pairing once the operator has confirmed the code: creates
/// the key, releases it to the app and waits for the app's result. Once the key
/// exists, every way the session ends that leaves it unused names the key and
/// where to delete it.
public struct KeyHandoff: Sendable {
    private let host: PairingHost
    private let cli: ViamCLI
    private let orgID: String
    private let orgName: String
    private let keyName: String

    public init(host: PairingHost, cli: ViamCLI, orgID: String, orgName: String, keyName: String) {
        self.host = host
        self.cli = cli
        self.orgID = orgID
        self.orgName = orgName
        self.keyName = keyName
    }

    /// `nextEvent` returns the host's next event, or nil once its events end.
    public func run(nextEvent: () async -> PairingHost.Event?) async -> PairingEnd {
        let hint = pairingDeleteHint(keyName)
        let key: (id: String, key: String)
        do {
            key = try await cli.createKey(orgID: orgID, name: keyName)
        } catch ViamCLIError.unparsableKey {
            await host.cancel()
            return PairingEnd(message: "The viam CLI created a key but its output couldn't be read. \(hint)", succeeded: false)
        } catch {
            await host.cancel()
            return PairingEnd(message: pairingCLIMessage(error), succeeded: false)
        }

        do {
            try await host.release(PairingPayload(orgID: orgID, orgName: orgName, keyID: key.id, key: key.key, keyName: keyName))
        } catch {
            return PairingEnd(message: "The pairing ended before the key was sent. \(hint)", succeeded: false)
        }

        while true {
            switch await nextEvent() {
            case .result(.stored, _):
                return PairingEnd(message: "Signed in to \(orgName).", succeeded: true)
            case .result(.rejected, let message):
                return PairingEnd(message: "The app couldn't use key \"\(keyName)\": \(message ?? "rejected"). \(hint)", succeeded: false)
            case .cancelledByApp:
                return PairingEnd(message: "Cancelled in the app after the key was created. \(hint)", succeeded: false)
            case .timedOut, nil:
                return PairingEnd(message: """
                    Timed out waiting for the app after creating key "\(keyName)". If the app's Settings → Organizations \
                    doesn't list \(orgName), \(hint.prefix(1).lowercased() + hint.dropFirst())
                    """, succeeded: false)
            case .connected:
                continue
            }
        }
    }
}
