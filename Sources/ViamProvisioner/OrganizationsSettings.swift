import ProvisionerKit
import SwiftUI

/// The organizations the signed-in Viam account can see.
struct OrganizationsSettings: View {
    let session: ViamSession
    let model: OrganizationsModel
    let environments: EnvironmentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountStatus(session: session)
            switch model.state {
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.small)
            case .idle, .loaded:
                if model.rows.isEmpty {
                    Text(isSignedIn ? "Your Viam account has no organizations." : "Sign in to see your organizations.")
                        .foregroundStyle(.secondary)
                } else {
                    List(model.rows) { org in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(org.name).bold()
                            let users = environments.usage(orgID: org.id).count
                            if users > 0 {
                                Text(users == 1 ? "Used by 1 environment" : "Used by \(users) environments")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Check Again") { Task { await model.load() } }
                    .disabled(!isSignedIn)
            }
        }
        .padding()
    }

    private var isSignedIn: Bool {
        if case .signedIn = session.state { true } else { false }
    }
}
