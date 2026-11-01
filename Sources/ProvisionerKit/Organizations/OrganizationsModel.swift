public import Foundation
public import Observation

/// One pairing session, from the app's side.
public protocol PairingSessionClient: Sendable {
    func hello() async throws -> (orgID: String, orgName: String, code: String)
    func awaitPayload() async throws -> PairingPayload
    func report(_ outcome: PairingResult.Outcome, message: String?) async throws
    func cancel() async
}

extension PairingClient: PairingSessionClient {}

/// The orgs the app is signed in to, and the pairing in progress.
@MainActor @Observable
public final class OrganizationsModel {
    public enum Status: Equatable, Sendable {
        case unchecked
        case checked(Date)
        case rejected(String)
        case unreachable(String)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var credential: OrgCredential
        public var status: Status
        public var id: String { credential.orgID }
    }

    public enum PairingState: Equatable, Sendable {
        case connecting
        case confirm(orgName: String, code: String)
        case validating(orgName: String)
        /// `warning` names a replaced key that couldn't be deleted in Viam.
        case signedIn(orgName: String, warning: String? = nil)
        case failed(String)

        var inProgress: Bool {
            switch self {
            case .connecting, .confirm, .validating: true
            case .signedIn, .failed: false
            }
        }
    }

    public private(set) var rows: [Row] = []
    /// Nil when no pairing sheet is showing.
    public private(set) var pairing: PairingState?

    private let store: any OrgCredentialStore
    private let validator: any CredentialValidator
    private let keyDeleter: any KeyDeleter
    private let makeClient: @Sendable (PairingLink) -> any PairingSessionClient
    private let now: @Sendable () -> Date
    private var client: (any PairingSessionClient)?
    private var pairingTask: Task<Void, Never>?

    public init(store: any OrgCredentialStore, validator: any CredentialValidator, keyDeleter: any KeyDeleter,
                makeClient: @escaping @Sendable (PairingLink) -> any PairingSessionClient = { PairingClient(link: $0) },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.validator = validator
        self.keyDeleter = keyDeleter
        self.makeClient = makeClient
        self.now = now
    }

    /// Reads the stored orgs and checks each key with Viam.
    public func load() async {
        rows = ((try? store.all()) ?? []).map { Row(credential: $0, status: .unchecked) }
        await recheck()
    }

    public func recheck() async {
        for index in rows.indices { rows[index].status = .unchecked }
        await withTaskGroup(of: (String, Status).self) { group in
            for row in rows {
                group.addTask { [validator, now] in
                    (row.id, Self.status(for: await validator.validate(row.credential), now: now()))
                }
            }
            for await (orgID, status) in group {
                if let index = rows.firstIndex(where: { $0.id == orgID }) { rows[index].status = status }
            }
        }
    }

    /// Starts pairing from a `viam-provisioner://pair` link. Ignored while a pairing
    /// is in progress. Returns the session's task, or nil when none started.
    @discardableResult
    public func handle(url: URL) -> Task<Void, Never>? {
        if pairing?.inProgress == true { return nil }
        guard let link = try? PairingLink(url: url) else {
            pairing = .failed("This pairing link isn't valid.")
            return nil
        }
        let client = makeClient(link)
        self.client = client
        pairing = .connecting
        let task = Task { await self.pair(with: client) }
        pairingTask = task
        return task
    }

    /// The operator pressed Cancel: tell the command and close the sheet.
    public func cancelPairing() async {
        let client = self.client
        pairing = nil
        self.client = nil
        await client?.cancel()
    }

    /// Closes a finished pairing's sheet.
    public func dismissPairing() {
        if pairing?.inProgress == false { pairing = nil }
    }

    /// Deletes the org's key from this device. It still exists in Viam.
    public func remove(orgID: String) throws {
        try store.remove(orgID: orgID)
        rows.removeAll { $0.id == orgID }
    }

    private func pair(with client: any PairingSessionClient) async {
        do {
            let hello = try await client.hello()
            guard isCurrent(client) else { return }
            pairing = .confirm(orgName: hello.orgName, code: hello.code)

            let payload = try await client.awaitPayload()
            guard isCurrent(client) else { return }
            pairing = .validating(orgName: payload.orgName)

            let credential = OrgCredential(payload, addedAt: now())
            let result = await validator.validate(credential)
            guard isCurrent(client) else { return }
            switch result {
            case .valid:
                let replaced = (try? store.all())?.first { $0.orgID == credential.orgID && $0.keyID != credential.keyID }
                do {
                    try store.save(credential)
                } catch {
                    try? await client.report(.rejected, message: "The app couldn't save the key to the Keychain.")
                    finish(client, .failed("Couldn't save the key to the Keychain: \(error)"))
                    return
                }
                rows.removeAll { $0.id == credential.orgID }
                rows.append(Row(credential: credential, status: .checked(now())))
                rows.sort { $0.credential.orgName < $1.credential.orgName }
                try? await client.report(.stored, message: nil)
                var warning: String?
                if let replaced {
                    do {
                        try await keyDeleter.deleteKey(id: replaced.keyID, using: credential)
                    } catch {
                        warning = "The replaced key \"\(replaced.keyName)\" is still in Viam (\(error)). Delete it in Viam's web UI."
                    }
                }
                finish(client, .signedIn(orgName: payload.orgName, warning: warning))
            case .rejected(let message):
                try? await client.report(.rejected, message: message)
                finish(client, .failed("Viam didn't accept the key: \(message)"))
            case .unreachable(let message):
                try? await client.report(.rejected, message: "The app couldn't reach Viam to check the key.")
                finish(client, .failed("Couldn't reach Viam to check the key: \(message)"))
            }
        } catch {
            guard isCurrent(client) else { return }
            finish(client, .failed(Self.message(for: error)))
        }
    }

    private func isCurrent(_ client: any PairingSessionClient) -> Bool {
        self.client.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
    }

    private func finish(_ client: any PairingSessionClient, _ state: PairingState) {
        guard isCurrent(client) else { return }
        pairing = state
        self.client = nil
    }

    nonisolated static func status(for result: ValidationResult, now: Date) -> Status {
        switch result {
        case .valid: .checked(now)
        case .rejected(let message): .rejected(message)
        case .unreachable(let message): .unreachable(message)
        }
    }

    static func message(for error: any Error) -> String {
        switch error as? PairingClientError {
        case .cancelled: "Pairing was cancelled in Terminal."
        case .timedOut: "The pairing timed out. Run 'just pair-app' again."
        case .alreadyPaired: "Another app already answered this pairing."
        case .invalidSession, .unexpectedStatus: "The pairing command didn't recognize this app. Run 'just pair-app' again."
        case .transport: "Lost contact with 'just pair-app'. Run it again."
        case nil: "Pairing failed: \(error)"
        }
    }
}
