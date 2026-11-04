import AppKit
import ProvisionerKit
import SwiftUI
import ViamAPI

@main
struct ViamProvisionerApp: App {
    @State private var organizations: OrganizationsModel
    @State private var environments: EnvironmentsModel

    init() {
        ImportEnvironmentCommand.runIfRequested()
        let organizations = OrganizationsModel(store: KeychainOrgCredentialStore(), validator: ViamCredentialValidator(), keyDeleter: ViamKeyDeleter())
        _organizations = State(initialValue: organizations)
        _environments = State(initialValue: EnvironmentsModel(
            store: FileEnvironmentStore(), orgs: { organizations.rows }, fleet: { ViamOrgFleet(credential: $0) }))
    }

    var body: some Scene {
        Window("Viam Provisioner", id: "main") {
            MainWindow(organizations: organizations, environments: environments)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    environments.load()
                    await organizations.load()
                }
                .onOpenURL { url in
                    NSApp.activate()
                    organizations.handle(url: url)
                }
                .sheet(isPresented: Binding(
                    get: { organizations.pairing != nil },
                    set: { presented in if !presented { organizations.dismissPairing() } }
                )) {
                    PairingSheet(model: organizations)
                }
        }
        .commands { EnvironmentCommands() }
        Settings {
            TabView {
                OrganizationsSettings(model: organizations, environments: environments)
                    .tabItem { Label("Organizations", systemImage: "building.2") }
            }
            .frame(width: 520, height: 360)
        }
    }
}
