import ProvisionerKit
import SwiftUI

/// The Viam API keys the app holds, with Add Key and Remove.
struct KeysSettings: View {
    let keys: ViamKeys
    let environments: EnvironmentsModel
    @State private var adding = false
    @State private var selection: String?
    @State private var removing: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = keys.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(keys.importProblems, id: \.self) { problem in
                Label("Keys file: \(problem)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if keys.keys.isEmpty && keys.unreadable.isEmpty {
                Text("No API keys. Add a key for an organization or a location to provision into Viam.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List(selection: $selection) {
                    ForEach(keys.keys) { key in
                        row(key).tag(key.keyID)
                    }
                    ForEach(keys.unreadable, id: \.self) { keyID in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unreadable key").bold()
                            Text("\(ViamAPIKey.shortID(keyID)) · its Keychain item couldn't be read")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        .tag(keyID)
                    }
                }
            }
            HStack {
                Button("Add Key…") { adding = true }
                Button("Remove…") { removing = selection }
                    .disabled(selection == nil)
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $adding) { AddKeyForm(keys: keys) }
        .confirmationDialog("Remove key \(removing.map(ViamAPIKey.shortID) ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) { if let keyID = removing { remove(keyID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is deleted from this Mac's Keychain. It stays valid at Viam.")
        }
        .alert("Couldn't remove the key", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(_ key: ViamAPIKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.scope.label).bold()
            HStack(spacing: 6) {
                Text(key.shortID).monospaced()
                let users = usage(key)
                if users > 0 { Text(users == 1 ? "· used by 1 environment" : "· used by \(users) environments") }
                if keys.rejected.contains(key.keyID) { Text("· rejected by Viam").foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The full-mode environments this key is the one used for.
    private func usage(_ key: ViamAPIKey) -> Int {
        environments.usage(orgID: key.scope.orgID).filter { environment in
            keys.key(org: key.scope.orgID, location: environment.locationID)?.keyID == key.keyID
        }.count
    }

    private func remove(_ keyID: String) {
        do {
            try keys.remove(keyID: keyID)
            selection = nil
        } catch {
            failure = String(describing: error)
        }
    }
}
