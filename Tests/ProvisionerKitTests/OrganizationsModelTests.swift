import Foundation
@testable import ProvisionerKit
import Testing

private struct FakeLister: OrganizationLister {
    let result: Result<[ViamOrganization], FleetError>
    /// What `GetOrganization` answers, by ID; IDs absent are refused.
    var granted: [String: Result<ViamOrganization, FleetError>] = [:]
    func organizations() async throws(FleetError) -> [ViamOrganization] { try result.get() }
    func organization(id: String) async throws(FleetError) -> ViamOrganization {
        try (granted[id] ?? .failure(.rejected("permission denied"))).get()
    }
}

/// A lister whose answer the test delivers once the model is waiting for it.
private actor HeldLister: OrganizationLister {
    private var answer: CheckedContinuation<Result<[ViamOrganization], FleetError>, Never>?
    private var called: [CheckedContinuation<Void, Never>] = []

    func organizations() async throws(FleetError) -> [ViamOrganization] {
        let result = await withCheckedContinuation { continuation in
            answer = continuation
            for waiter in called { waiter.resume() }
            called = []
        }
        return try result.get()
    }

    func waitUntilCalled() async {
        if answer != nil { return }
        await withCheckedContinuation { called.append($0) }
    }

    func finish(_ result: Result<[ViamOrganization], FleetError>) {
        answer?.resume(returning: result)
        answer = nil
    }
}

@MainActor @Suite struct OrganizationsModelTests {
    @Test func loadsOrgsFromLister() async {
        let orgs = [ViamOrganization(id: "o1", name: "Acme"), ViamOrganization(id: "o2", name: "Beta")]
        let model = OrganizationsModel(lister: FakeLister(result: .success(orgs)))
        await model.load()
        #expect(model.rows == orgs)
        #expect(model.state == .loaded)
    }

    @Test func listerFailureIsFailedWithMessage() async {
        let model = OrganizationsModel(lister: FakeLister(result: .failure(.unreachable("offline"))))
        await model.load()
        #expect(model.rows.isEmpty)
        #expect(model.state == .failed("Couldn't list your Viam organizations: offline"))
    }

    /// Signing out while a load is in flight: its late failure must not raise a banner.
    @Test func loadFinishingAfterClearIsDiscarded() async {
        let lister = HeldLister()
        let model = OrganizationsModel(lister: lister)
        let loading = Task { await model.load() }
        await lister.waitUntilCalled()
        model.clear()
        await lister.finish(.failure(.rejected("Sign in to Viam.")))
        await loading.value
        #expect(model.state == .idle)
        #expect(model.rows.isEmpty)
    }

    @Test func clearEmptiesRows() async {
        let model = OrganizationsModel(lister: FakeLister(result: .success([ViamOrganization(id: "o1", name: "Acme")])))
        await model.load()
        model.clear()
        #expect(model.rows.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func listedOrgsAreMarkedListed() async {
        let model = OrganizationsModel(lister: FakeLister(result: .success([ViamOrganization(id: "o1", name: "Acme")])))
        await model.load()
        #expect(model.listed)
    }

    /// A key Viam won't list organizations for: the orgs it's granted are read one by one.
    @Test func refusedListFallsBackToTheGrantedCandidates() async {
        let acme = ViamOrganization(id: "o1", name: "Acme")
        let lister = FakeLister(result: .failure(.rejected("permission denied")), granted: ["o1": .success(acme)])
        let model = OrganizationsModel(lister: lister, candidates: { ["o1", "o2", "o1"] })
        await model.load()
        #expect(model.rows == [acme])
        #expect(model.state == .loaded)
        #expect(!model.listed)
    }

    @Test func refusedListWithNoGrantedCandidateFails() async {
        let lister = FakeLister(result: .failure(.rejected("permission denied")))
        let model = OrganizationsModel(lister: lister, candidates: { ["o2"] })
        await model.load()
        #expect(model.rows.isEmpty)
        #expect(model.state == .failed("Couldn't list your Viam organizations: permission denied"))
    }

    /// A candidate Viam couldn't answer for may be granted, so nothing is concluded.
    @Test func unreachableCandidateFailsTheLoad() async {
        let lister = FakeLister(result: .failure(.rejected("permission denied")),
                                granted: ["o1": .success(ViamOrganization(id: "o1", name: "Acme")), "o2": .failure(.unreachable("offline"))])
        let model = OrganizationsModel(lister: lister, candidates: { ["o1", "o2"] })
        await model.load()
        #expect(model.state == .failed("Couldn't list your Viam organizations: offline"))
    }

    @Test func grantedOrgsAreSortedByName() async {
        let lister = FakeLister(result: .failure(.rejected("permission denied")),
                                granted: ["o1": .success(ViamOrganization(id: "o1", name: "Zeta")),
                                          "o2": .success(ViamOrganization(id: "o2", name: "alpha"))])
        let model = OrganizationsModel(lister: lister, candidates: { ["o1", "o2"] })
        await model.load()
        #expect(model.rows.map(\.name) == ["alpha", "Zeta"])
    }

    @Test func clearForgetsThatTheOrgsWereGrantsOnly() async {
        let lister = FakeLister(result: .failure(.rejected("permission denied")),
                                granted: ["o1": .success(ViamOrganization(id: "o1", name: "Acme"))])
        let model = OrganizationsModel(lister: lister, candidates: { ["o1"] })
        await model.load()
        model.clear()
        #expect(model.listed)
    }
}
