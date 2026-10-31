import AppKit
import SwiftUI

/// How to connect an org: run the pairing command in Terminal.
struct OnboardingView: View {
    var title = "Connect a Viam organization"
    let command: String
    var waiting = true

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.title2.bold())
            Text("In Terminal, from the provisioner repo, run:")
            HStack(spacing: 10) {
                Text(command).font(.body.monospaced()).textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("It uses your viam CLI login, asks which org, makes a key just for this app, and hands it over. You won't see or paste the key.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a pairing…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
    }
}
