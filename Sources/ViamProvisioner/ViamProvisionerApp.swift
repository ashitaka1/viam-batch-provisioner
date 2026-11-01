import AppKit
import ProvisionerKit
import SwiftUI
import ViamAPI

@main
struct ViamProvisionerApp: App {
    @State private var model = OrganizationsModel(store: KeychainOrgCredentialStore(), validator: ViamCredentialValidator(), keyDeleter: ViamKeyDeleter())

    var body: some Scene {
        Window("Viam Provisioner", id: "main") {
            MainView(model: model)
                .frame(minWidth: 480, minHeight: 320)
                .task { await model.load() }
                .onOpenURL { url in
                    NSApp.activate()
                    model.handle(url: url)
                }
                .sheet(isPresented: Binding(
                    get: { model.pairing != nil },
                    set: { presented in if !presented { model.dismissPairing() } }
                )) {
                    PairingSheet(model: model)
                }
        }
        Settings {
            TabView {
                OrganizationsSettings(model: model)
                    .tabItem { Label("Organizations", systemImage: "building.2") }
            }
            .frame(width: 520, height: 360)
        }
    }
}

struct MainView: View {
    let model: OrganizationsModel

    var body: some View {
        if let loadError = model.loadError {
            VStack(spacing: 12) {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.load() } }
            }
            .padding(32)
            .frame(maxWidth: 420)
        } else if model.rows.isEmpty {
            OnboardingView(command: "just pair-app")
        } else {
            VStack(spacing: 12) {
                Text(model.rows.count == 1 ? "Signed in to 1 organization" : "Signed in to \(model.rows.count) organizations")
                    .font(.title2)
                ForEach(model.rows) { row in
                    Text(row.credential.orgName)
                }
                SettingsLink { Text("Manage organizations…") }
            }
            .padding(32)
        }
    }
}
