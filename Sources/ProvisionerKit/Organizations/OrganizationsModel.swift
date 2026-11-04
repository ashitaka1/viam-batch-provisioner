public import Observation

/// The Viam organizations the signed-in account can see.
@MainActor @Observable
public final class OrganizationsModel {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// In the lister's order.
    public private(set) var rows: [ViamOrganization] = []
    public private(set) var state: LoadState = .idle

    private let lister: any OrganizationLister
    /// Bumped by each load and clear, so a superseded load's answer is dropped.
    private var generation = 0

    public init(lister: any OrganizationLister) {
        self.lister = lister
    }

    public func load() async {
        generation += 1
        let current = generation
        state = .loading
        do {
            let orgs = try await lister.organizations()
            guard current == generation else { return }
            rows = orgs
            state = .loaded
        } catch {
            guard current == generation else { return }
            rows = []
            let message = switch error {
            case .rejected(let message), .failed(let message), .unreachable(let message): message
            }
            state = .failed("Couldn't list your Viam organizations: \(message)")
        }
    }

    /// Forgets the orgs, after signing out.
    public func clear() {
        generation += 1
        rows = []
        state = .idle
    }
}
