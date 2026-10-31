import ProvisionerKit
import SwiftUI

struct PairingSheet: View {
    let model: OrganizationsModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.pairing {
            case .connecting, nil:
                ProgressView("Connecting to Terminal…")
                cancel
            case .confirm(let orgName, let code):
                Text("Add **\(orgName)**?").font(.title2)
                VStack(spacing: 4) {
                    Text("Confirm code").foregroundStyle(.secondary)
                    Text(code.map(String.init).joined(separator: " "))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    Text("in Terminal").foregroundStyle(.secondary)
                }
                cancel
            case .validating(let orgName):
                ProgressView("Checking the key for \(orgName) with Viam…")
            case .signedIn(let orgName):
                Label("Signed in to \(orgName)", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                done
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                done
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private var cancel: some View {
        Button("Cancel", role: .cancel) { Task { await model.cancelPairing() } }
            .keyboardShortcut(.cancelAction)
    }

    private var done: some View {
        Button("Done") { model.dismissPairing() }
            .keyboardShortcut(.defaultAction)
    }
}
