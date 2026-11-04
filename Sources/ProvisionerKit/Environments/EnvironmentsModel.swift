public import Foundation
public import Observation

/// The environments on this Mac, and the Viam locations their orgs offer.
@MainActor @Observable
public final class EnvironmentsModel {
    public enum LocationsState: Equatable, Sendable {
        case idle
        case loading
        case loaded([ViamLocation])
        case rejected(String)
        /// Viam couldn't be reached, or answered with an error.
        case unreachable(String)
        /// Signed out, the account's orgs are unknown, or it can't see this one.
        case unavailable
    }

    /// Sorted by name, ignoring case.
    public private(set) var environments: [Environment] = []
    /// Why the stored environments couldn't be read, when they couldn't.
    public private(set) var loadError: String?
    private var locationStates: [String: LocationsState] = [:]
    /// Environments whose stored WiFi password isn't a WPA passphrase, found when
    /// it was set or loaded, so problems never read the Keychain.
    private var badWifiPasswords: Set<UUID> = []

    private let store: any EnvironmentStore
    private let orgs: @MainActor () -> AccountOrgs
    private let fleet: @Sendable (_ orgID: String) -> any ViamFleet
    private let readFile: @MainActor (String) -> String?
    private let home: String

    public init(store: any EnvironmentStore, orgs: @escaping @MainActor () -> AccountOrgs,
                fleet: @escaping @Sendable (_ orgID: String) -> any ViamFleet,
                readFile: @escaping @MainActor (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                home: String = NSHomeDirectory()) {
        self.store = store
        self.orgs = orgs
        self.fleet = fleet
        self.readFile = readFile
        self.home = home
    }

    public func load() {
        do {
            environments = try store.all()
            loadError = nil
            badWifiPasswords = []
            for environment in environments where environment.hasWifiPassword {
                if let secrets = try? store.secrets(id: environment.id) { record(secrets, id: environment.id) }
            }
        } catch {
            environments = []
            loadError = error.localizedDescription
        }
    }

    // MARK: Lifecycle

    /// A new environment under an unused name, with the org preselected when
    /// the account sees exactly one, and `~/.ssh/id_ed25519.pub` as its key when that parses.
    @discardableResult
    public func create(name: String = "New Environment", mode: ProvisionMode = .full) throws -> Environment {
        var environment = Environment.new(name: unusedName(name))
        environment.provisionMode = mode
        if case .known(let orgs) = orgs(), orgs.count == 1 {
            environment.orgID = orgs[0].id
            environment.orgName = orgs[0].name
        }
        if let key = readFile("\(home)/.ssh/id_ed25519.pub"), case .success = SSHPublicKey.parse(key) {
            environment.sshPublicKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try store.save(environment, secrets: EnvironmentSecrets())
        try refresh()
        return try stored(environment.id)
    }

    /// A copy named "<name> copy", secrets included.
    @discardableResult
    public func duplicate(id: UUID) throws -> Environment {
        var copy = try stored(id)
        copy.id = UUID()
        copy.name = unusedName("\(copy.name) copy")
        let secrets = try store.secrets(id: id)
        try store.save(copy, secrets: secrets)
        record(secrets, id: copy.id)
        try refresh()
        return try stored(copy.id)
    }

    /// Refuses an empty name, or one another environment has in any case.
    public func rename(id: UUID, to name: String) throws {
        var environment = try stored(id)
        environment.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameProblems = environment.problems(otherNames: otherNames(than: id)).filter { $0.field == .name }
        guard nameProblems.isEmpty else { throw EnvironmentError.invalid(nameProblems) }
        try update(environment)
    }

    /// Saves the environment's settings, problems and all; its secrets are kept.
    public func update(_ environment: Environment) throws {
        try store.save(environment, secrets: nil)
        try refresh()
    }

    public func delete(id: UUID) throws {
        defer { try? refresh() }
        try store.remove(id: id)
        badWifiPasswords.remove(id)
    }

    // MARK: Secrets

    /// Stores the SHA-512 crypt hash of `plaintext`; nil or empty clears it.
    public func setPassword(_ plaintext: String?, id: UUID) throws {
        var secrets = try store.secrets(id: id)
        secrets.passwordHash = plaintext.flatMap { $0.isEmpty ? nil : SHA512Crypt.hash($0) }
        try save(secrets, id: id)
    }

    /// Sets the WiFi password or Tailscale key; nil or empty clears it.
    public func setSecret(_ field: EnvironmentField, _ value: String?, id: UUID) throws {
        var secrets = try store.secrets(id: id)
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        switch field {
        case .wifiPassword: secrets.wifiPassword = value
        case .tailscaleAuthKey: secrets.tailscaleAuthKey = value
        default: preconditionFailure("\(field) isn't a revealable secret")
        }
        try save(secrets, id: id)
    }

    /// The WiFi password or Tailscale key. The OS password is kept only as a hash.
    public func revealSecret(_ field: EnvironmentField, id: UUID) throws -> String? {
        let secrets = try store.secrets(id: id)
        switch field {
        case .wifiPassword: return secrets.wifiPassword
        case .tailscaleAuthKey: return secrets.tailscaleAuthKey
        default: preconditionFailure("\(field) isn't a revealable secret")
        }
    }

    private func save(_ secrets: EnvironmentSecrets, id: UUID) throws {
        try store.save(try stored(id), secrets: secrets)
        record(secrets, id: id)
        try refresh()
    }

    private func record(_ secrets: EnvironmentSecrets, id: UUID) {
        if let password = secrets.wifiPassword, !Environment.isWPAPassphrase(password) {
            badWifiPasswords.insert(id)
        } else {
            badWifiPasswords.remove(id)
        }
    }

    // MARK: Problems and orgs

    /// Every reason the environment can't provision: its own rules, its secrets
    /// as last set, and, in full mode, the health of its org and location.
    public func problems(for environment: Environment) -> [EnvironmentProblem] {
        var problems = environment.problems(otherNames: otherNames(than: environment.id))
        if badWifiPasswords.contains(environment.id), environment.hasWifiPassword, !(environment.wifiSSID ?? "").isEmpty {
            problems.append(EnvironmentProblem(field: .wifiPassword, message: "WiFi passwords are 8 to 63 characters."))
        }
        guard environment.provisionMode == .full, let orgID = environment.orgID, !orgID.isEmpty else { return problems }
        let orgName = environment.orgName ?? orgID
        let orgs: [ViamOrganization]
        switch self.orgs() {
        case .signedOut:
            problems.append(EnvironmentProblem(field: .org, message: "Sign in to Viam to use \(orgName)."))
            return problems
        case .unknown:
            return problems
        case .known(let known):
            orgs = known
        }
        guard orgs.contains(where: { $0.id == orgID }) else {
            problems.append(EnvironmentProblem(field: .org, message: "Your Viam account can't see \(orgName)."))
            return problems
        }
        if let locationID = environment.locationID, !locationID.isEmpty,
           case .loaded(let locations) = locationStates[orgID], !locations.contains(where: { $0.id == locationID }) {
            let locationName = environment.locationName ?? locationID
            problems.append(EnvironmentProblem(field: .location, message: "\"\(locationName)\" no longer exists in \(orgName)."))
        }
        return problems
    }

    public func orgIsAvailable(_ environment: Environment) -> Bool {
        guard let orgID = environment.orgID else { return false }
        return isAvailable(orgID)
    }

    /// The full-mode environments that use the org.
    public func usage(orgID: String) -> [Environment] {
        environments.filter { $0.provisionMode == .full && $0.orgID == orgID }
    }

    public func locations(org orgID: String) -> LocationsState {
        guard isAvailable(orgID) else { return .unavailable }
        return locationStates[orgID] ?? .idle
    }

    /// Fetches the org's locations unless they are loaded or loading.
    public func loadLocations(org orgID: String) async {
        switch locations(org: orgID) {
        case .loaded, .loading, .unavailable: return
        case .idle, .rejected, .unreachable: await fetchLocations(org: orgID)
        }
    }

    public func reloadLocations(org orgID: String) async {
        if case .loading = locations(org: orgID) { return }
        await fetchLocations(org: orgID)
    }

    private func fetchLocations(org orgID: String) async {
        guard isAvailable(orgID) else { return }
        locationStates[orgID] = .loading
        do {
            locationStates[orgID] = .loaded(try await fleet(orgID).locations())
        } catch {
            switch error {
            case .rejected(let message): locationStates[orgID] = .rejected(message)
            case .failed(let message), .unreachable(let message): locationStates[orgID] = .unreachable(message)
            }
        }
    }

    // MARK: Helpers

    private func isAvailable(_ orgID: String) -> Bool {
        guard case .known(let orgs) = orgs() else { return false }
        return orgs.contains { $0.id == orgID }
    }

    private func refresh() throws {
        environments = try store.all()
        loadError = nil
    }

    private func stored(_ id: UUID) throws -> Environment {
        guard let environment = try store.all().first(where: { $0.id == id }) else {
            throw EnvironmentError.invalid([EnvironmentProblem(field: .name, message: "That environment no longer exists.")])
        }
        return environment
    }

    private func otherNames(than id: UUID) -> [String] {
        environments.filter { $0.id != id }.map(\.name)
    }

    private func unusedName(_ base: String) -> String {
        let taken = Set(environments.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
