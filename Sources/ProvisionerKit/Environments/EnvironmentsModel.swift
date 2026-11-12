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
        /// Signed out, the orgs are unknown, or no key reaches this one.
        case unavailable
    }

    /// Sorted by name, ignoring case.
    public private(set) var environments: [Environment] = []
    /// Why the stored environments couldn't be read, when they couldn't.
    public private(set) var loadError: String?
    private var locationStates: [String: LocationsState] = [:]
    /// Orgs whose loaded locations are the location keys' grants, not Viam's list.
    private var grantedOnly: Set<String> = []
    /// Environments whose stored WiFi password isn't a WPA passphrase, found when
    /// it was set or loaded, so problems never read the Keychain.
    private var badWifiPasswords: Set<UUID> = []
    /// Each open editor's unsaved edit and the environment it edits, by editor;
    /// saving one updates the store.
    @ObservationIgnored private var pendingEdits: [UUID: (environment: UUID, commit: @MainActor () -> Void)] = [:]

    private let store: any EnvironmentStore
    private let orgs: @MainActor () -> AccountOrgs
    private let fleet: @MainActor (_ orgID: String, _ locationID: String?) -> (any ViamFleet)?
    private let grantedLocations: @MainActor (_ orgID: String) -> [ViamLocation]?
    private let reaches: (@MainActor (_ orgID: String, _ locationID: String) -> Bool)?
    private let readFile: @MainActor (String) -> String?
    private let home: String

    /// `fleet` makes Viam's calls with the stored key that covers the org and
    /// location, nil when none does (decision 49). `grantedLocations` are the
    /// org's locations the keys are granted when no key holds the whole org,
    /// nil when one does. `reaches` says whether `fleet` would return one, without
    /// making it, for checks that run while views render.
    public init(store: any EnvironmentStore, orgs: @escaping @MainActor () -> AccountOrgs,
                fleet: @escaping @MainActor (_ orgID: String, _ locationID: String?) -> (any ViamFleet)?,
                grantedLocations: @escaping @MainActor (_ orgID: String) -> [ViamLocation]? = { _ in nil },
                reaches: (@MainActor (_ orgID: String, _ locationID: String) -> Bool)? = nil,
                readFile: @escaping @MainActor (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                home: String = NSHomeDirectory()) {
        self.store = store
        self.orgs = orgs
        self.fleet = fleet
        self.grantedLocations = grantedLocations
        self.reaches = reaches
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

    /// Registers how `editor` saves its unsaved edit to `environment`, or clears it with nil.
    public func setPendingEdit(for editor: UUID, environment: UUID, _ commit: (@MainActor () -> Void)?) {
        pendingEdits[editor] = commit.map { (environment, $0) }
    }

    /// Saves the unsaved edits open editors hold for one environment, so what's
    /// read next is what was typed.
    public func commitPendingEdits(environment id: UUID) {
        for edit in pendingEdits.values where edit.environment == id { edit.commit() }
    }

    /// The environment as stored once open editors' unsaved edits to it are saved.
    public func saved(id: UUID) -> Environment? {
        commitPendingEdits(environment: id)
        return environments.first { $0.id == id }
    }

    /// A copy named "<name> copy", secrets included.
    @discardableResult
    public func duplicate(id: UUID) throws -> Environment {
        commitPendingEdits(environment: id)
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

    // MARK: Provisioning

    public struct ProvisioningSettings: Sendable {
        public var config: EnvironmentConfig
        /// The calls into the environment's org and location, in full mode.
        public var fleet: (any ViamFleet)?
    }

    /// What a batch is provisioned with. Throws every problem the environment
    /// has, its secrets and org included.
    public func provisioningSettings(id: UUID) throws -> ProvisioningSettings {
        let environment = try stored(id)
        let secrets = try store.secrets(id: id)
        var problems = self.problems(for: environment)
        let config: EnvironmentConfig?
        do {
            config = try environment.config(secrets: secrets)
        } catch .invalid(let more) {
            problems += more.filter { !problems.contains($0) }
            config = nil
        }
        guard let config, problems.isEmpty else { throw EnvironmentError.invalid(problems) }
        let fleet = environment.provisionMode == .full ? environment.orgID.flatMap { self.fleet($0, environment.locationID) } : nil
        return ProvisioningSettings(config: config, fleet: fleet)
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
            problems.append(EnvironmentProblem(field: .org, message: "Add a Viam API key to use \(orgName)."))
            return problems
        case .unknown:
            return problems
        case .known(let known):
            orgs = known
        }
        guard orgs.contains(where: { $0.id == orgID }) else {
            problems.append(EnvironmentProblem(field: .org, message: Self.notReachable))
            return problems
        }
        if let locationID = environment.locationID, !locationID.isEmpty {
            if !isReached(orgID, locationID) {
                problems.append(EnvironmentProblem(field: .location, message: Self.notReachable))
            } else if case .loaded(let locations) = locationStates[orgID], !grantedOnly.contains(orgID),
                      !locations.contains(where: { $0.id == locationID }) {
                let locationName = environment.locationName ?? locationID
                problems.append(EnvironmentProblem(field: .location, message: "\"\(locationName)\" no longer exists in \(orgName)."))
            }
        }
        return problems
    }

    public static let notReachable = "Not reachable with this key"

    /// The stored keys leave out the environment's org or location. Its stored
    /// org and location are kept.
    public func isUnreachableWithKey(_ environment: Environment) -> Bool {
        guard environment.provisionMode == .full, let orgID = environment.orgID, !orgID.isEmpty,
              case .known(let orgs) = orgs() else { return false }
        guard orgs.contains(where: { $0.id == orgID }) else { return true }
        guard let locationID = environment.locationID, !locationID.isEmpty else { return false }
        return !isReached(orgID, locationID)
    }

    private func isReached(_ orgID: String, _ locationID: String) -> Bool {
        reaches?(orgID, locationID) ?? (fleet(orgID, locationID) != nil)
    }

    /// Forgets every org's locations, when the keys change: what one key reached
    /// says nothing about the next.
    public func forgetLocations() {
        locationStates = [:]
        grantedOnly = []
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

    /// Loads the locations of each reachable org with an environment that holds
    /// a location ID without its name, as an import leaves it, so the sidebar
    /// can name it.
    public func nameLocations() async {
        let orgIDs = Set(environments.compactMap { environment -> String? in
            guard environment.provisionMode == .full, environment.locationName == nil,
                  !(environment.locationID ?? "").isEmpty, let orgID = environment.orgID else { return nil }
            return orgID
        })
        for orgID in orgIDs.sorted() { await loadLocations(org: orgID) }
    }

    private func fetchLocations(org orgID: String) async {
        guard isAvailable(orgID) else { return }
        if let granted = grantedLocations(orgID) {
            locationStates[orgID] = .loaded(granted)
            grantedOnly.insert(orgID)
            storeLocationNames(granted, org: orgID)
            return
        }
        grantedOnly.remove(orgID)
        guard let fleet = fleet(orgID, nil) else {
            locationStates[orgID] = .unavailable
            return
        }
        locationStates[orgID] = .loading
        do {
            let locations = try await fleet.locations()
            locationStates[orgID] = .loaded(locations)
            storeLocationNames(locations, org: orgID)
        } catch {
            switch error {
            case .rejected(let message): locationStates[orgID] = .rejected(message)
            case .failed(let message), .unreachable(let message): locationStates[orgID] = .unreachable(message)
            }
        }
    }

    /// Saves the current name of each of the org's environments' locations. A
    /// save that fails leaves the name as it was; the editor saves it again.
    private func storeLocationNames(_ locations: [ViamLocation], org orgID: String) {
        var changed = false
        for var environment in environments where environment.orgID == orgID {
            guard let location = locations.first(where: { $0.id == environment.locationID }),
                  environment.locationName != location.name else { continue }
            environment.locationName = location.name
            if (try? store.save(environment, secrets: nil)) != nil { changed = true }
        }
        if changed { try? refresh() }
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
