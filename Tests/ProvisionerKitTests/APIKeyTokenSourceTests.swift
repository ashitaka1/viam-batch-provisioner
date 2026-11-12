import Foundation
@testable import ProvisionerKit
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// An unsigned JWT whose `exp` is `seconds` after `now`. `padding` lengthens the
/// payload so its base64 needs the URL-safe `-` and `_` characters.
func jwt(expiresIn seconds: TimeInterval, padding: String = "") -> String {
    let payload = Data(#"{"exp":\#(Int(now.timeIntervalSince1970 + seconds)),"p":"\#(padding)"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

/// Viam's `AuthService/Authenticate`, scripted.
final class ScriptedAuth: @unchecked Sendable {
    enum Outcome { case token(String), refused, unreachable }

    private let lock = NSLock()
    private var outcome = Outcome.token(jwt(expiresIn: 3600))
    private var _calls: [(id: String, key: String)] = []

    var calls: [(id: String, key: String)] { lock.withLock { _calls } }
    func answer(_ outcome: Outcome) { lock.withLock { self.outcome = outcome } }

    var authenticate: APIKeyTokenSource.Authenticate {
        { id, key in
            let outcome = self.lock.withLock {
                self._calls.append((id, key))
                return self.outcome
            }
            switch outcome {
            case .token(let token): return token
            case .refused: throw APIKeyRefused()
            case .unreachable: throw URLError(.notConnectedToInternet)
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private func source(_ auth: ScriptedAuth, onRejected: @escaping @Sendable () async -> Void = {}) -> APIKeyTokenSource {
    APIKeyTokenSource(keyID: "kid", key: "kval", authenticate: auth.authenticate, now: { now }, onRejected: onRejected)
}

@Suite struct APIKeyTokenSourceTests {
    @Test func exchangesTheKeyItWasMadeWith() async throws {
        let auth = ScriptedAuth()
        _ = try await source(auth).token(refresh: false)
        #expect(auth.calls.map(\.id) == ["kid"])
        #expect(auth.calls.map(\.key) == ["kval"])
    }

    @Test func tokenIsCachedUntilItNearsExpiry() async throws {
        let auth = ScriptedAuth()
        auth.answer(.token(jwt(expiresIn: 61)))
        let tokens = source(auth)
        _ = try await tokens.token(refresh: false)
        _ = try await tokens.token(refresh: false)
        #expect(auth.calls.count == 1, "a token 61 s from expiry was exchanged again")

        auth.answer(.token(jwt(expiresIn: 59)))
        _ = try await tokens.token(refresh: true)
        _ = try await tokens.token(refresh: false)
        #expect(auth.calls.count == 3, "a token 59 s from expiry was reused")
    }

    @Test func urlSafeBase64PayloadIsDecoded() async throws {
        let token = jwt(expiresIn: 3600, padding: "??>>??>>~~")
        #expect(token.contains("-") || token.contains("_"), "the fixture doesn't exercise base64url")
        let auth = ScriptedAuth()
        auth.answer(.token(token))
        let tokens = source(auth)
        _ = try await tokens.token(refresh: false)
        _ = try await tokens.token(refresh: false)
        #expect(auth.calls.count == 1)
    }

    @Test func refreshReturnsTheNewToken() async throws {
        let auth = ScriptedAuth()
        let tokens = source(auth)
        _ = try await tokens.token(refresh: false)
        let newer = jwt(expiresIn: 7200)
        auth.answer(.token(newer))
        #expect(try await tokens.token(refresh: true) == newer)
    }

    @Test func refusedKeyThrowsAndReportsTheRejection() async {
        let auth = ScriptedAuth()
        auth.answer(.refused)
        let rejections = Counter()
        let tokens = source(auth) { rejections.add() }
        await #expect(throws: APIKeyRefused.self) { try await tokens.token(refresh: false) }
        #expect(rejections.value == 1, "rejection reported \(rejections.value) times")
    }

    @Test func unreachableViamIsNoRejection() async {
        let auth = ScriptedAuth()
        auth.answer(.unreachable)
        let rejections = Counter()
        let tokens = source(auth) { rejections.add() }
        await #expect(throws: URLError.self) { try await tokens.token(refresh: false) }
        #expect(rejections.value == 0, "rejection reported \(rejections.value) times")
    }

    @Test func aFailedExchangeIsTriedAgainOnTheNextCall() async throws {
        let auth = ScriptedAuth()
        let tokens = source(auth)
        auth.answer(.unreachable)
        await #expect(throws: URLError.self) { try await tokens.token(refresh: false) }
        auth.answer(.refused)
        await #expect(throws: APIKeyRefused.self) { try await tokens.token(refresh: false) }
        auth.answer(.token("fresh"))
        #expect(try await tokens.token(refresh: false) == "fresh")
        #expect(auth.calls.count == 3, "exchanges: \(auth.calls.count)")
    }

    @Test func tokenWithoutAnExpiryIsCachedUntilRefresh() async throws {
        let auth = ScriptedAuth()
        auth.answer(.token("opaque-token"))
        let tokens = source(auth)
        _ = try await tokens.token(refresh: false)
        _ = try await tokens.token(refresh: false)
        #expect(auth.calls.count == 1, "exchanges: \(auth.calls.count)")
    }

    @Test func rejectedTokenReportsTheRejectionAndExchangesAgain() async throws {
        let auth = ScriptedAuth()
        let rejections = Counter()
        let tokens = source(auth) { rejections.add() }
        _ = try await tokens.token(refresh: false)
        await tokens.rejected()
        _ = try await tokens.token(refresh: false)
        #expect(rejections.value == 1, "rejection reported \(rejections.value) times")
        #expect(auth.calls.count == 2, "exchanges: \(auth.calls.count)")
    }

    /// Calls at launch arrive together; they share one Authenticate exchange.
    @Test func concurrentCallersShareOneExchange() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let calls = Counter()
        let tokens = APIKeyTokenSource(keyID: "kid", key: "kval", authenticate: { _, _ in
            calls.add()
            for await _ in gate.stream { break }
            return "shared-token"
        }, now: { now })
        // A refresh bypasses the cache, so a second caller arriving after the first
        // finished would start its own exchange and fail the count below.
        async let first = tokens.token(refresh: true)
        async let second = tokens.token(refresh: true)
        // Both callers are waiting once the one exchange has started.
        let deadline = ContinuousClock.now + .seconds(5)
        while calls.value == 0 && ContinuousClock.now < deadline { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        // Twice, so a second exchange, were one started, finishes too.
        gate.continuation.yield()
        gate.continuation.yield()
        #expect(try await [first, second] == ["shared-token", "shared-token"])
        #expect(calls.value == 1, "exchanges: \(calls.value)")
    }
}
