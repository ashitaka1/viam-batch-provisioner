import Foundation
public import ProvisionerKit

public enum PairingHostError: Error, Equatable, Sendable {
    case wrongNonce
    case alreadyConnected
    /// The request's app key isn't the one that said hello, or no app has.
    case unknownSession
    /// The revealed key and nonce don't match the hello's commitment.
    case commitmentMismatch
    case cancelled
    case timedOut
    case finished
}

/// The command's side of one pairing session, independent of transport: accepts
/// the first app that says hello, takes its commitment, shows the code once the
/// app reveals what it committed to, hands it the sealed key once the operator
/// confirms, and ends on the app's result, a cancel from either side, or a
/// deadline: `timeout` from creation until the key is released, then
/// `resultTimeout` for the app to validate and report.
public actor PairingHost {
    public enum Event: Equatable, Sendable {
        case connected(code: String)
        case cancelledByApp
        case result(PairingResult.Outcome, message: String?)
        case timedOut
    }

    private enum State {
        case waiting
        case committed(Data)
        case connected(appKey: String, secrets: PairingSecrets)
        case released(appKey: String, sealed: Data)
        case ended(PairingHostError)
    }

    public nonisolated let nonce: PairingNonce
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let orgID: String
    private let orgName: String
    private let keys = PairingKeyPair()
    private var state = State.waiting
    private var keyWaiters: [CheckedContinuation<Data, any Error>] = []
    private var keyRequestedWaiters: [CheckedContinuation<Void, Never>] = []
    /// The current deadline. The first starts in `init`, so no request can arrive before it exists.
    private var deadline: Task<Void, any Error>
    private var deadlineGeneration = 0
    private let resultTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void


    /// How long the app has, after the key is released, to report the result.
    public static let defaultResultTimeout: Duration = .seconds(120)

    public init(orgID: String, orgName: String, nonce: PairingNonce = .random(), timeout: Duration = .seconds(120),
                resultTimeout: Duration = PairingHost.defaultResultTimeout,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.orgID = orgID
        self.orgName = orgName
        self.nonce = nonce
        self.resultTimeout = resultTimeout
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream()
        let deadline = Task { try await sleep(timeout) }
        self.deadline = deadline
        Task { await self.endAt(deadline, generation: 0) }
    }

    private func endAt(_ deadline: Task<Void, any Error>, generation: Int) async {
        guard (try? await deadline.value) != nil, generation == deadlineGeneration else { return }
        end(.timedOut, event: .timedOut)
    }

    private func restartDeadline(_ duration: Duration) {
        deadline.cancel()
        deadlineGeneration += 1
        let generation = deadlineGeneration
        let sleep = self.sleep
        let deadline = Task { try await sleep(duration) }
        self.deadline = deadline
        Task { await self.endAt(deadline, generation: generation) }
    }

    // MARK: Requests from the app

    public func hello(_ hello: PairingHello) throws -> PairingHelloReply {
        guard hello.nonce == nonce.base64URL else { throw PairingHostError.wrongNonce }
        switch state {
        case .waiting: break
        case .ended(let error): throw error
        case .committed, .connected, .released: throw PairingHostError.alreadyConnected
        }
        guard let commitment = Data(base64Encoded: hello.commitment), commitment.count == 32 else {
            throw PairingHostError.unknownSession
        }
        state = .committed(commitment)
        return PairingHelloReply(commandPublicKey: keys.publicKey.base64EncodedString(), orgID: orgID, orgName: orgName)
    }

    /// The app reveals the key and nonce it committed to; the code is shown only now.
    public func reveal(_ reveal: PairingReveal) throws {
        guard reveal.nonce == nonce.base64URL else { throw PairingHostError.wrongNonce }
        let commitment: Data
        switch state {
        case .committed(let committed): commitment = committed
        case .ended(let error): throw error
        case .waiting, .connected, .released: throw PairingHostError.unknownSession
        }
        guard let appKey = Data(base64Encoded: reveal.appPublicKey),
              let appNonce = PairingNonce(base64URL: reveal.appNonce),
              PairingCommitment.verify(commitment, appPublicKey: appKey, appNonce: appNonce) else {
            throw PairingHostError.commitmentMismatch
        }
        let secrets: PairingSecrets
        do {
            secrets = try PairingSecrets(own: keys, peerPublicKey: appKey, nonce: nonce, commandPublicKey: keys.publicKey,
                                         appPublicKey: appKey, appNonce: appNonce)
        } catch {
            throw PairingHostError.commitmentMismatch
        }
        state = .connected(appKey: reveal.appPublicKey, secrets: secrets)
        continuation.yield(.connected(code: secrets.code))
    }

    /// Returns once the operator confirms; throws if the session ends first.
    public func awaitKey(_ request: PairingSessionRequest) async throws -> PairingSealed {
        try checkSession(request.nonce, request.appPublicKey)
        if case .released(_, let sealed) = state { return PairingSealed(sealed: sealed.base64EncodedString()) }
        let sealed = try await withCheckedThrowingContinuation { waiter in
            keyWaiters.append(waiter)
            for waiter in keyRequestedWaiters { waiter.resume() }
            keyRequestedWaiters = []
        }
        return PairingSealed(sealed: sealed.base64EncodedString())
    }

    public func report(_ result: PairingResult) throws {
        try checkSession(result.nonce, result.appPublicKey)
        guard case .released = state else { throw PairingHostError.unknownSession }
        end(.finished, event: .result(result.outcome, message: result.message))
    }

    public func appCancel(_ request: PairingSessionRequest) throws {
        try checkSession(request.nonce, request.appPublicKey)
        end(.cancelled, event: .cancelledByApp)
    }

    // MARK: From the command

    /// Seals the key for the connected app. Call only after the operator confirms the code.
    public func release(_ payload: PairingPayload) throws {
        switch state {
        case .waiting, .committed, .released: throw PairingHostError.unknownSession
        case .ended(let error): throw error
        case .connected(let appKey, let secrets):
            let sealed = try secrets.seal(payload)
            state = .released(appKey: appKey, sealed: sealed)
            restartDeadline(resultTimeout)
            for waiter in keyWaiters { waiter.resume(returning: sealed) }
            keyWaiters = []
        }
    }

    /// The operator declined or the command is stopping.
    public func cancel() {
        end(.cancelled, event: nil)
    }

    // MARK: Internals

    /// Suspends until an app is parked waiting for the key.
    func waitUntilKeyRequested() async {
        if !keyWaiters.isEmpty { return }
        await withCheckedContinuation { keyRequestedWaiters.append($0) }
    }

    private func checkSession(_ requestNonce: String, _ appKey: String) throws {
        guard requestNonce == nonce.base64URL else { throw PairingHostError.wrongNonce }
        switch state {
        case .waiting, .committed: throw PairingHostError.unknownSession
        case .ended(let error): throw error
        case .connected(let connected, _), .released(let connected, _):
            guard connected == appKey else { throw PairingHostError.unknownSession }
        }
    }

    private func end(_ error: PairingHostError, event: Event?) {
        if case .ended = state { return }
        state = .ended(error)
        deadline.cancel()
        for waiter in keyWaiters { waiter.resume(throwing: error) }
        keyWaiters = []
        for waiter in keyRequestedWaiters { waiter.resume() }
        keyRequestedWaiters = []
        if let event { continuation.yield(event) }
        continuation.finish()
    }
}
