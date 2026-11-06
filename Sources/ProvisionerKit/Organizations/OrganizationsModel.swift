public import Observation

/// The Viam organizations the signed-in account can see. Where Viam refuses to
/// list them, as for some API keys, the candidates are read one by one, and those
/// Viam answers for are the ones the credential is granted.
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
    /// False when the rows were read one by one after Viam refused the list.
    public private(set) var listed = true

    private let lister: any OrganizationLister
    private let candidates: @MainActor () -> [String]
    /// Bumped by each load and clear, so a superseded load's answer is dropped.
    private var generation = 0

    /// `candidates` are org IDs worth reading when the list is refused: the
    /// environments' orgs and the CLI's default.
    public init(lister: any OrganizationLister, candidates: @escaping @MainActor () -> [String] = { [] }) {
        self.lister = lister
        self.candidates = candidates
    }

    public func load() async {
        generation += 1
        let current = generation
        state = .loading
        do {
            let (orgs, listed) = try await read()
            guard current == generation else { return }
            rows = orgs
            self.listed = listed
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

    private func read() async throws(FleetError) -> ([ViamOrganization], listed: Bool) {
        do {
            return (try await lister.organizations(), true)
        } catch .rejected(let message) {
            var seen = Set<String>()
            var granted: [ViamOrganization] = []
            for id in candidates() where seen.insert(id).inserted {
                do {
                    granted.append(try await lister.organization(id: id))
                } catch .rejected {
                    continue
                }
            }
            guard !granted.isEmpty else { throw .rejected(message) }
            return (granted.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, false)
        }
    }

    /// Forgets the orgs, after signing out.
    public func clear() {
        generation += 1
        rows = []
        listed = true
        state = .idle
    }
}
