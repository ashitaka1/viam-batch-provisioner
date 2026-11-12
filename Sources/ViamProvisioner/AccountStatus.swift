import ProvisionerKit
import SwiftUI

/// The toolbar's sign-in status: the keys the app holds, and the way to add one.
struct AccountStatus: View {
    let keys: ViamKeys
    @State private var adding = false

    var body: some View {
        Group {
            if !keys.loaded {
                ProgressView().controlSize(.small)
            } else if keys.isSignedIn {
                Menu {
                    Button("Add API Key…") { adding = true }
                    SettingsLink { Text("Manage API Keys…") }
                } label: {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(keys.rejected.isEmpty ? .green : .orange)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .menuIndicator(.visible)
                .fixedSize()
            } else {
                AddKeyButton(adding: $adding)
            }
        }
        .help(help)
        .sheet(isPresented: $adding) { AddKeyForm(keys: keys) }
    }

    private var title: String {
        keys.keys.count == 1 ? keys.keys[0].scope.label : "\(keys.keys.count) API keys"
    }

    private var help: String {
        if !keys.rejected.isEmpty { return "Viam rejected a stored key. Remove it in Settings." }
        return keys.keys.map { "\($0.scope.label) (\($0.shortID))" }.joined(separator: "\n")
    }
}

/// Opens the form for pasting a key.
struct AddKeyButton: View {
    @Binding var adding: Bool

    var body: some View {
        Button {
            adding = true
        } label: {
            Label {
                Text("Add Viam API Key…")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
