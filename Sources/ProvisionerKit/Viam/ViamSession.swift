public import Foundation
public import Observation

/// Whether the app is signed in to Viam, through the `viam` CLI's login.
@MainActor @Observable
public final class ViamSession {
    public enum State: Equatable, Sendable {
        case checking
        case cliMissing
        case signedOut
        /// `code` is the device code to match on Viam's device-login page, once
        /// the CLI has printed it.
        case signingIn(code: String?)
        /// `account` is nil when the CLI couldn't say who is signed in.
        case signedIn(account: String?)
        case failed(String)
    }

    public nonisolated static let defaultBaseURL = URL(string: "https://app.viam.com")!

    public private(set) var state: State = .checking
    public let baseURL: URL
    public nonisolated let tokens: any BearerTokenProvider

    private let resolver: CLIResolver
    private let tokenSource: CLITokenSource
    private var loginTask: Task<Void, any Error>?

    public init(locate: @escaping @Sendable () async -> URL? = { await ViamCLI.locate() },
                makeCLI: @escaping @Sendable (URL) -> ViamCLI = { ViamCLI(run: ViamCLI.processRunner(executable: $0)) },
                baseURL: URL = CLIConfig.baseURL() ?? ViamSession.defaultBaseURL,
                now: @escaping @Sendable () -> Date = Date.init) {
        let resolver = CLIResolver(locate: locate, makeCLI: makeCLI)
        self.resolver = resolver
        self.baseURL = baseURL
        let box = WeakSession()
        let source = CLITokenSource(cli: { try await resolver.cli() }, now: now,
                                    onSignedOut: { await box.session?.signedOutElsewhere() })
        tokenSource = source
        tokens = source
        box.session = self
    }

    /// Reads the CLI's login.
    public func load() async {
        do {
            let cli = try await resolver.cli()
            _ = try await tokenSource.token(refresh: true)
            // The token was read, so a whoami failure says nothing about the login.
            let account = try? await cli.whoami()
            state = .signedIn(account: account.map { $0.contains("@") ? $0 : "API key" })
        } catch {
            state = await state(for: error)
        }
    }

    /// Runs `viam login`, which opens the browser. Only from `.signedOut`: a failed
    /// read says nothing about whether the CLI holds a login, so it gets `load()`.
    public func signIn() async {
        guard state == .signedOut else { return }
        state = .signingIn(code: nil)
        let task = Task { [resolver, weak self] in
            try await resolver.cli().login { code in
                Task { @MainActor in self?.showCode(code) }
            }
        }
        loginTask = task
        do {
            try await task.value
            guard loginTask == task else { return }
            loginTask = nil
            await load()
        } catch {
            guard loginTask == task else { return }
            loginTask = nil
            state = await state(for: error)
        }
    }

    public func cancelSignIn() {
        loginTask?.cancel()
        loginTask = nil
        if case .signingIn = state { state = .signedOut }
    }

    private func showCode(_ code: String) {
        if case .signingIn = state { state = .signingIn(code: code) }
    }

    /// Runs `viam logout`, which also signs the CLI out in Terminal.
    public func signOut() async {
        do {
            try await resolver.cli().logout()
            await tokenSource.clear()
            state = .signedOut
        } catch {
            // Whatever logout left behind, show the CLI's login as it now is.
            await load()
        }
    }

    private func signedOutElsewhere() {
        if case .signedIn = state { state = .signedOut }
    }

    private func state(for error: any Error) async -> State {
        if case .notInstalled? = error as? ViamCLIError { await resolver.forget() }
        return switch error as? ViamCLIError {
        case .notInstalled: .cliMissing
        case .notLoggedIn: .signedOut
        case .failed(let stderr): .failed(stderr.isEmpty ? "The viam CLI failed." : stderr)
        case .tokenUnavailable: .failed("The viam CLI couldn't give the app its login.")
        default: error is CancellationError ? .signedOut : .failed("The viam CLI failed: \(error)")
        }
    }
}

@MainActor
private final class WeakSession: Sendable {
    weak var session: ViamSession?
}

/// The located CLI, found once. A missing or vanished CLI is looked for again.
private actor CLIResolver {
    private let locate: @Sendable () async -> URL?
    private let makeCLI: @Sendable (URL) -> ViamCLI
    private var found: ViamCLI?

    init(locate: @escaping @Sendable () async -> URL?, makeCLI: @escaping @Sendable (URL) -> ViamCLI) {
        self.locate = locate
        self.makeCLI = makeCLI
    }

    /// After the located binary vanished, so the next call looks for it again.
    func forget() {
        found = nil
    }

    func cli() async throws -> ViamCLI {
        if let found { return found }
        guard let url = await locate() else { throw ViamCLIError.notInstalled }
        let cli = makeCLI(url)
        found = cli
        return cli
    }
}
