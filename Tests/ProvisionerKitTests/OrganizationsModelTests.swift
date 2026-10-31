import Foundation
@testable import ProvisionerKit
import Testing

/// A pairing command the test scripts: hello answers at once; the payload
/// arrives when the test delivers it.
actor FakePairingClient: PairingSessionClient {
    let orgID: String
    let orgName: String
    let code: String
    private var payloadWaiter: CheckedContinuation<PairingPayload, any Error>?
    private var awaitingWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reports: [(PairingResult.Outcome, String?)] = []
    private(set) var cancelled = false

    init(orgID: String = "o1", orgName: String = "Acme", code: String = "4729") {
        self.orgID = orgID
        self.orgName = orgName
        self.code = code
    }

    func hello() async throws -> (orgID: String, orgName: String, code: String) { (orgID, orgName, code) }

    func awaitPayload() async throws -> PairingPayload {
        try await withCheckedThrowingContinuation { waiter in
            payloadWaiter = waiter
            for waiter in awaitingWaiters { waiter.resume() }
            awaitingWaiters = []
        }
    }

    func report(_ outcome: PairingResult.Outcome, message: String?) async throws { reports.append((outcome, message)) }

    func cancel() async {
        cancelled = true
        payloadWaiter?.resume(throwing: PairingClientError.cancelled)
        payloadWaiter = nil
    }

    /// Suspends until the model is waiting for the key.
    func waitUntilAwaitingPayload() async {
        if payloadWaiter != nil { return }
        await withCheckedContinuation { awaitingWaiters.append($0) }
    }

    func deliver(keyName: String = "provisioner-app studio 2026-10-31") async {
        await waitUntilAwaitingPayload()
        payloadWaiter?.resume(returning: PairingPayload(orgID: orgID, orgName: orgName, keyID: "kid-\(orgID)", key: "kval", keyName: keyName))
        payloadWaiter = nil
    }

    func fail(_ error: PairingClientError) async {
        await waitUntilAwaitingPayload()
        payloadWaiter?.resume(throwing: error)
        payloadWaiter = nil
    }

    var reportedOutcomes: [PairingResult.Outcome] { reports.map(\.0) }
}

struct FakeValidator: CredentialValidator {
    let results: [String: ValidationResult]
    var fallback: ValidationResult = .valid(orgName: "Acme")

    func validate(_ credential: OrgCredential) async -> ValidationResult { results[credential.orgID] ?? fallback }
}

private let now = Date(timeIntervalSince1970: 1_793_500_000)
private let link = PairingLink(host: "127.0.0.1", port: 50_000, nonce: .random())

private func stored(_ orgID: String, _ name: String) -> OrgCredential {
    OrgCredential(PairingPayload(orgID: orgID, orgName: name, keyID: "kid-\(orgID)", key: "k", keyName: "old key"),
                  addedAt: Date(timeIntervalSince1970: 0))
}

@MainActor
private func makeModel(store: InMemoryOrgCredentialStore = InMemoryOrgCredentialStore(),
                       validator: FakeValidator = FakeValidator(results: [:]),
                       clients: [FakePairingClient]) -> (OrganizationsModel, MadeClients) {
    let made = MadeClients(clients)
    let model = OrganizationsModel(store: store, validator: validator, makeClient: { _ in made.next() }, now: { now })
    return (model, made)
}

final class MadeClients: @unchecked Sendable {
    private var queue: [FakePairingClient]
    private(set) var count = 0
    private let lock = NSLock()
    init(_ clients: [FakePairingClient]) { queue = clients }
    func next() -> FakePairingClient { lock.withLock { count += 1; return queue.removeFirst() } }
}

@MainActor @Test(.timeLimit(.minutes(1))) func pairingFlowStoresAfterValidation() async throws {
    let client = FakePairingClient()
    let store = InMemoryOrgCredentialStore()
    let (model, _) = makeModel(store: store, clients: [client])

    let pairing = try #require(model.handle(url: link.url))
    await client.waitUntilAwaitingPayload()
    #expect(model.pairing == .confirm(orgName: "Acme", code: "4729"))

    await client.deliver()
    await pairing.value
    #expect(model.pairing == .signedIn(orgName: "Acme"))
    #expect(try store.all().map(\.orgID) == ["o1"])
    #expect(model.rows.map(\.status) == [.checked(now)])
    #expect(await client.reportedOutcomes == [.stored])
}

@MainActor @Test(.timeLimit(.minutes(1))) func rejectedKeyIsNotStored() async throws {
    let client = FakePairingClient()
    let store = InMemoryOrgCredentialStore()
    let (model, _) = makeModel(store: store, validator: FakeValidator(results: ["o1": .rejected("bad key")]), clients: [client])

    let pairing = try #require(model.handle(url: link.url))
    await client.deliver()
    await pairing.value
    #expect(try store.all().isEmpty)
    #expect(model.rows.isEmpty)
    #expect(await client.reports.map { "\($0.0) \($0.1 ?? "")" } == ["rejected bad key"])
    guard case .failed = model.pairing else { Issue.record("expected .failed, got \(String(describing: model.pairing))"); return }
}

@MainActor @Test(.timeLimit(.minutes(1))) func unreachableDuringPairingStoresNothing() async throws {
    let client = FakePairingClient()
    let store = InMemoryOrgCredentialStore()
    let (model, _) = makeModel(store: store, validator: FakeValidator(results: ["o1": .unreachable("offline")]), clients: [client])

    let pairing = try #require(model.handle(url: link.url))
    await client.deliver()
    await pairing.value
    #expect(try store.all().isEmpty)
    #expect(await client.reportedOutcomes == [.rejected])
}

@MainActor @Test(.timeLimit(.minutes(1))) func unreachableDoesNotMarkRejected() async throws {
    let store = InMemoryOrgCredentialStore([stored("o1", "Acme")])
    let (model, _) = makeModel(store: store, validator: FakeValidator(results: ["o1": .unreachable("offline")]), clients: [])
    await model.load()
    #expect(model.rows.map(\.status) == [.unreachable("offline")])
    #expect(try store.all().map(\.orgID) == ["o1"], "the key is kept")
}

@MainActor @Test(.timeLimit(.minutes(1))) func secondLinkIgnoredDuringPairing() async throws {
    let client = FakePairingClient()
    let (model, made) = makeModel(clients: [client, FakePairingClient(orgID: "o2", orgName: "Other")])
    _ = model.handle(url: link.url)
    await client.waitUntilAwaitingPayload()
    #expect(model.handle(url: PairingLink(host: "127.0.0.1", port: 50_001, nonce: .random()).url) == nil)
    #expect(made.count == 1, "made \(made.count) clients")
    #expect(model.pairing == .confirm(orgName: "Acme", code: "4729"))
}

@MainActor @Test(.timeLimit(.minutes(1))) func linkAfterFinishedPairingStartsNewOne() async throws {
    let first = FakePairingClient()
    let second = FakePairingClient(orgID: "o2", orgName: "Beta", code: "1111")
    let (model, _) = makeModel(clients: [first, second])
    let pairing = try #require(model.handle(url: link.url))
    await first.deliver()
    await pairing.value
    _ = try #require(model.handle(url: link.url))
    await second.waitUntilAwaitingPayload()
    #expect(model.pairing == .confirm(orgName: "Beta", code: "1111"))
}

@MainActor @Test(.timeLimit(.minutes(1))) func cancelTellsCommand() async throws {
    let client = FakePairingClient()
    let (model, _) = makeModel(clients: [client])
    let pairing = try #require(model.handle(url: link.url))
    await client.waitUntilAwaitingPayload()
    await model.cancelPairing()
    await pairing.value
    #expect(await client.cancelled)
    #expect(model.pairing == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func commandDeclineShowsFailure() async throws {
    let client = FakePairingClient()
    let (model, _) = makeModel(clients: [client])
    let pairing = try #require(model.handle(url: link.url))
    await client.fail(.cancelled)
    await pairing.value
    #expect(model.pairing == .failed("Pairing was cancelled in Terminal."))
}

@MainActor @Test(.timeLimit(.minutes(1))) func repairReplacesRow() async throws {
    let first = FakePairingClient()
    let second = FakePairingClient()
    let store = InMemoryOrgCredentialStore()
    let (model, _) = makeModel(store: store, clients: [first, second])
    let a = try #require(model.handle(url: link.url))
    await first.deliver(keyName: "key one")
    await a.value
    let b = try #require(model.handle(url: link.url))
    await second.deliver(keyName: "key two")
    await b.value
    #expect(model.rows.map(\.credential.keyName) == ["key two"])
    #expect(try store.all().count == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func badLinkShowsFailure() {
    let (model, made) = makeModel(clients: [])
    #expect(model.handle(url: URL(string: "viam-provisioner://pair?host=127.0.0.1&port=5&nonce=bad")!) == nil)
    #expect(model.pairing == .failed("This pairing link isn't valid."))
    #expect(made.count == 0)
}

@MainActor @Test(.timeLimit(.minutes(1))) func loadChecksEveryOrg() async {
    let store = InMemoryOrgCredentialStore([stored("o1", "Acme"), stored("o2", "Beta")])
    let validator = FakeValidator(results: ["o1": .valid(orgName: "Acme"), "o2": .rejected("revoked")])
    let (model, _) = makeModel(store: store, validator: validator, clients: [])
    await model.load()
    #expect(model.rows.map(\.credential.orgName) == ["Acme", "Beta"])
    #expect(model.rows.map(\.status) == [.checked(now), .rejected("revoked")])
}

@MainActor @Test(.timeLimit(.minutes(1))) func removeDeletesRowAndKey() async throws {
    let store = InMemoryOrgCredentialStore([stored("o1", "Acme"), stored("o2", "Beta")])
    let (model, _) = makeModel(store: store, clients: [])
    await model.load()
    try model.remove(orgID: "o1")
    #expect(model.rows.map(\.credential.orgID) == ["o2"])
    #expect(try store.all().map(\.orgID) == ["o2"])
}

/// A validator that holds its answer until the test releases it.
actor GatedValidator: CredentialValidator {
    private var waiter: CheckedContinuation<ValidationResult, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func validate(_ credential: OrgCredential) async -> ValidationResult {
        await withCheckedContinuation { waiter = $0; for s in started { s.resume() }; started = [] }
    }

    func waitUntilValidating() async {
        if waiter != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func answer(_ result: ValidationResult) {
        waiter?.resume(returning: result)
        waiter = nil
    }
}

struct FailingStore: OrgCredentialStore {
    struct Failure: Error {}
    func all() throws -> [OrgCredential] { [] }
    func save(_ credential: OrgCredential) throws { throw Failure() }
    func remove(orgID: String) throws {}
}

@MainActor @Test(.timeLimit(.minutes(1))) func cancelDuringValidationStoresNothing() async throws {
    let client = FakePairingClient()
    let validator = GatedValidator()
    let store = InMemoryOrgCredentialStore()
    let model = OrganizationsModel(store: store, validator: validator, makeClient: { _ in client }, now: { now })
    let pairing = try #require(model.handle(url: link.url))
    await client.deliver()
    await validator.waitUntilValidating()
    await model.cancelPairing()
    await validator.answer(.valid(orgName: "Acme"))
    await pairing.value
    #expect(try store.all().isEmpty, "a cancelled pairing must not keep the key")
    #expect(model.rows.isEmpty)
    #expect(model.pairing == nil)
    let reported = await client.reportedOutcomes
    #expect(reported.isEmpty, "reported \(reported)")
}

@MainActor @Test(.timeLimit(.minutes(1))) func savingFailureReportsRejectedAndShowsNoRow() async throws {
    let client = FakePairingClient()
    let model = OrganizationsModel(store: FailingStore(), validator: FakeValidator(results: [:]), makeClient: { _ in client }, now: { now })
    let pairing = try #require(model.handle(url: link.url))
    await client.deliver()
    await pairing.value
    #expect(model.rows.isEmpty)
    #expect(await client.reportedOutcomes == [.rejected])
    guard case .failed = model.pairing else { Issue.record("expected .failed, got \(String(describing: model.pairing))"); return }
}
