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
    private let fleet: @Sendable (String) -> any ViamFleet

    init() {
        ImportEnvironmentCommand.runIfRequested()
        HelperDaemonCommand.runIfRequested()
        let session = ViamSession()
        let tokens = session.tokens
        let baseURL = session.baseURL
        let organizations = OrganizationsModel(lister: ViamOrganizationLister(tokens: tokens, baseURL: baseURL))
        let fleet: @Sendable (String) -> any ViamFleet = { ViamOrgFleet(orgID: $0, tokens: tokens, baseURL: baseURL) }
        self.fleet = fleet
        _session = State(initialValue: session)
        _organizations = State(initialValue: organizations)
        _environments = State(initialValue: EnvironmentsModel(
            store: FileEnvironmentStore(),
            orgs: {
                switch session.state {
                case .signedIn: organizations.state == .loaded ? .known(organizations.rows) : .unknown
                case .checking: .unknown
                case .cliMissing, .signedOut, .signingIn, .failed: .signedOut
                }
            },
            fleet: fleet))
    }

    var body: some Scene {
        Window("Viam Provisioner", id: "main") {
            MainWindow(session: session, organizations: organizations, environments: environments,
                       servers: servers, history: history, fleet: fleet)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    environments.load()
                    history.load()
                    await session.load()
                }
                .onChange(of: session.state) { _, state in
                    if case .signedIn = state {
                        Task { await organizations.load() }
                    } else if state == .signedOut {
                        organizations.clear()
                    }
                }
                // The scheme stays registered for a later OAuth callback; key handoff links are ignored.
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
