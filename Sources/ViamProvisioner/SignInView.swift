import ProvisionerKit
import SwiftUI

/// The detail pane while the app holds no Viam API key.
struct SignInView: View {
    let keys: ViamKeys
    @State private var adding = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Add a Viam API Key").font(.title2.bold())
            Text("Create an API key for an organization or a location at app.viam.com, then paste its ID and key. The app acts with that key's access alone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if let error = keys.loadError {
                Text(error).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            AddKeyButton(adding: $adding).buttonStyle(.borderedProminent)
        }
        .padding(32)
        .sheet(isPresented: $adding) { AddKeyForm(keys: keys) }
    }
}

/// Pasting a key's ID and secret, and saying whether it is an organization's or
/// a location's. The key is checked with Viam and its scope worked out before
/// it is stored; on failure nothing is stored and the key field is cleared.
struct AddKeyForm: View {
    let keys: ViamKeys
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var keyID = ""
    @State private var key = ""
    @State private var kind = APIKeyKind.organization
    @State private var scopeID = ""
    @State private var checking = false
    @State private var error: KeyCheckError?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Viam API Key").font(.headline)
            Form {
                TextField("Key ID", text: $keyID)
                SecureField("Key", text: $key)
                Picker("Scope", selection: $kind) {
                    Text("Organization").tag(APIKeyKind.organization)
                    Text("Location").tag(APIKeyKind.location)
                }
                .pickerStyle(.segmented)
                // A constant label: the form's label column takes the widest label, so a
                // label that changed with the scope would resize the picker on every click.
                TextField("ID", text: $scopeID, prompt: Text(scopeIDPrompt))
            }
            .disabled(checking)
            if let error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking with Viam…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || isBlank(keyID) || isBlank(key) || (scopeRequired && isBlank(scopeID)))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var scopeRequired: Bool { error == .needsScopeID }

    private var scopeIDPrompt: String {
        let what = switch kind {
        case .organization: "Organization ID"
        case .location: "Location ID"
        }
        return "\(what), \(scopeRequired ? "required" : "optional")"
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() async {
        checking = true
        defer { checking = false }
        do {
            try await keys.add(keyID: keyID, key: key, kind: kind, scopeID: scopeID)
            dismiss()
        } catch {
            self.error = error
            // A key Viam refused is pasted again; any other failure keeps it for another try.
            if error == .rejected { key = "" }
        }
    }
}
