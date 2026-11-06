import AppKit
import ProvisionerKit
import SwiftUI
import ViamAPI

@main
struct ViamProvisionerApp: App {
    @State private var session: ViamSession
    @State private var organizations: OrganizationsModel
    @State private var environments: EnvironmentsModel
    @State private var servers = ServerSelection()
    @State private var history = BatchHistory()

    init() {
        ImportEnvironmentCommand.runIfRequested()
        HelperDaemonCommand.runIfRequested()
        let baseURL = CLIConfig.baseURL() ?? ViamSession.defaultBaseURL
        let session = ViamSession(baseURL: baseURL, authenticate: { try await ViamAppClient.authenticate(keyID: $0, key: $1, baseURL: baseURL) })
        let tokens = session.tokens
        // Candidates for a key Viam won't list organizations for: the environments' orgs and the CLI's default.
        let environmentsRef = WeakRef<EnvironmentsModel>()
        let organizations = OrganizationsModel(
            lister: ViamOrganizationLister(tokens: tokens, baseURL: baseURL),
            candidates: { (environmentsRef.value?.orgIDsInUse ?? []) + [CLIConfig.defaults().org].compactMap { $0 } })
        let environments = EnvironmentsModel(
            store: FileEnvironmentStore(),
            orgs: {
                switch session.state {
                case .signedIn: organizations.state == .loaded ? .known(organizations.rows) : .unknown
                case .checking: .unknown
                case .cliMissing, .signedOut, .signingIn, .failed: .signedOut
                }
            },
            fleet: { ViamOrgFleet(orgID: $0, tokens: tokens, baseURL: baseURL) },
            keyLogin: { if case .signedIn(.apiKey) = session.state { true } else { false } },
            defaultLocation: { CLIConfig.defaults().location })
        environmentsRef.value = environments
        _session = State(initialValue: session)
        _organizations = State(initialValue: organizations)
        _environments = State(initialValue: environments)
    }

    var body: some Scene {
        Window("Viam Provisioner", id: "main") {
            MainWindow(session: session, organizations: organizations, environments: environments,
                       servers: servers, history: history)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    environments.load()
                    history.load()
                    await session.load()
                }
                .onChange(of: session.state) { _, state in
                    if case .signedIn = state {
                        Task {
                            await organizations.load()
                            // Each environment's reach, and a single org's locations for the key's scope.
                            if organizations.rows.count == 1 { await environments.loadLocations(org: organizations.rows[0].id) }
                            await environments.loadLocationsInUse()
                        }
                    } else if state == .signedOut {
                        organizations.clear()
                    }
                }
                // The scheme stays registered for a later OAuth callback; pairing links are ignored.
                .onOpenURL { _ in NSApp.activate() }
        }
        .commands { EnvironmentCommands() }
        Settings {
            TabView {
                OrganizationsSettings(session: session, model: organizations, environments: environments)
                    .tabItem { Label("Organizations", systemImage: "building.2") }
            }
            .frame(width: 520, height: 360)
        }
    }
}

@MainActor
private final class WeakRef<Value: AnyObject> {
    weak var value: Value?
}
