import ProvisionerKit

/// An in-memory Viam location with scripted failures. Machine `<name>` gets ID
/// `m-<name>`, main part `p-<name>` and secret `s-<name>`.
actor FakeFleet: ViamFleet {
    enum Call: Equatable {
        case machines
        case create(String)
        case mainPart(String)
        case delete(String)
    }

    enum CreateOutcome {
        case fail(FleetError)
        /// The machine is created, but the call reports `.unreachable`.
        case createdThenUnreachable
        /// As above, with Viam holding the name in a different case.
        case createdAsThenUnreachable(String)
    }

    let location = "loc-1"
    private(set) var calls: [Call] = []
    /// Every location argument the fleet was called with.
    private(set) var locationsUsed: Set<String> = []
    private(set) var machines: [ViamMachine]
    private let createOutcomes: [String: CreateOutcome]
    private let partFailures: [String: FleetError]
    private let deleteFailures: [String: FleetError]
    private let listingFailure: FleetError?
    private let listingFailureAfterCreate: FleetError?
    private let holdAfterCreating: String?
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        existing: [String] = [],
        createOutcomes: [String: CreateOutcome] = [:],
        partFailures: [String: FleetError] = [:],
        deleteFailures: [String: FleetError] = [:],
        listingFailure: FleetError? = nil,
        listingFailureAfterCreate: FleetError? = nil,
        holdAfterCreating: String? = nil
    ) {
        machines = existing.map { ViamMachine(id: "m-\($0)", name: $0) }
        self.createOutcomes = createOutcomes
        self.partFailures = partFailures
        self.deleteFailures = deleteFailures
        self.listingFailure = listingFailure
        self.listingFailureAfterCreate = listingFailureAfterCreate
        self.holdAfterCreating = holdAfterCreating
    }

    var names: [String] { machines.map(\.name) }

    /// What `locations()` returns, and how many times it was called.
    private var locationsOutcome: Result<[ViamLocation], FleetError> = .success([ViamLocation(id: "loc-1", name: "Bench")])
    private(set) var locationsCalls = 0

    func setLocations(_ outcome: Result<[ViamLocation], FleetError>) { locationsOutcome = outcome }

    func locations() async throws(FleetError) -> [ViamLocation] {
        locationsCalls += 1
        return try locationsOutcome.get()
    }

    func machines(location: String) async throws(FleetError) -> [ViamMachine] {
        calls.append(.machines)
        locationsUsed.insert(location)
        if let listingFailure { throw listingFailure }
        if let listingFailureAfterCreate, calls.contains(where: { if case .create = $0 { true } else { false } }) {
            throw listingFailureAfterCreate
        }
        return machines
    }

    func createMachine(name: String, location: String) async throws(FleetError) -> String {
        calls.append(.create(name))
        locationsUsed.insert(location)
        switch createOutcomes[name] {
        case .fail(let error)?:
            throw error
        case .createdThenUnreachable?:
            machines.append(ViamMachine(id: "m-\(name)", name: name))
            throw .unreachable("connection reset")
        case .createdAsThenUnreachable(let stored)?:
            machines.append(ViamMachine(id: "m-\(name)", name: stored))
            throw .unreachable("connection reset")
        case nil:
            machines.append(ViamMachine(id: "m-\(name)", name: name))
        }
        if name == holdAfterCreating {
            for waiter in holdWaiters { waiter.resume() }
            holdWaiters = []
            await withCheckedContinuation { held = $0 }
        }
        return "m-\(name)"
    }

    func mainPart(machine: String) async throws(FleetError) -> MachinePart {
        calls.append(.mainPart(machine))
        // A real call over URLSession fails when its task is cancelled.
        if Task.isCancelled { throw .unreachable("cancelled") }
        let name = String(machine.dropFirst(2))
        if let failure = partFailures[name] { throw failure }
        return MachinePart(id: "p-\(name)", secret: "s-\(name)")
    }

    func deleteMachine(id: String) async throws(FleetError) {
        calls.append(.delete(id))
        if let failure = deleteFailures[String(id.dropFirst(2))] { throw failure }
        machines.removeAll { $0.id == id }
    }

    /// Returns once `holdAfterCreating` has been created and is held.
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
