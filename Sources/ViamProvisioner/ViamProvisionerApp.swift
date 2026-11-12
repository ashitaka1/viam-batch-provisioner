import AppKit
import Foundation
import ProvisionerKit
import SwiftUI
import ViamAPI

@main
struct ViamProvisionerApp: App {
    @State private var keys: ViamKeys
    @State private var environments: EnvironmentsModel
    @State private var servers = ServerSelection()
    @State private var history = BatchHistory()

    init() {
        ImportEnvironmentCommand.runIfRequested()
        NetbootDaemonCommand.runIfRequested()
        UserNotificationPoster.prepare()
        let keys = ViamKeys.app()
        _keys = State(initialValue: keys)
        _environments = State(initialValue: EnvironmentsModel(
            store: FileEnvironmentStore(),
            orgs: { keys.orgs },
            fleet: { keys.fleet(org: $0, location: $1) },
            grantedLocations: { keys.grantedLocations(org: $0) },
            reaches: { keys.key(org: $0, location: $1) != nil }))
    }

    var body: some Scene {
        Window("Viam Provisioner", id: "main") {
            MainWindow(keys: keys, environments: environments, servers: servers, history: history)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    environments.load()
                    history.load()
                    keys.load()
                    if let path = ProcessInfo.processInfo.environment[KeysFile.environmentVariable], !path.isEmpty {
                        await keys.importKeys(fromFile: path)
                    }
                }
                .onChange(of: keys.keys) {
                    // What one set of keys reached says nothing about the next.
                    environments.forgetLocations()
                }
                .task(id: keys.orgs) { await environments.nameLocations() }
                // The scheme stays registered for a later OAuth callback; key handoff links are ignored.
                .onOpenURL { _ in NSApp.activate() }
        }
        .commands { EnvironmentCommands() }
        Settings {
            TabView {
                KeysSettings(keys: keys, environments: environments)
                    .tabItem { Label("API Keys", systemImage: "key") }
            }
            .frame(width: 560, height: 380)
        }
    }
}

extension ViamKeys {
    /// The app's keys, in the login keychain, calling Viam at the base URL the app's defaults name.
    static func app() -> ViamKeys {
        let baseURL = ViamAppClient.baseURL()
        return ViamKeys(
            store: KeychainAPIKeyStore(),
            authenticate: { try await ViamAppClient.authenticate(keyID: $0, key: $1, baseURL: baseURL) },
            probe: { ViamKeyProbe(keyID: $0, key: $1, baseURL: baseURL) },
            makeFleet: { ViamOrgFleet(orgID: $0, tokens: $1, baseURL: baseURL) })
    }
}
