import ProvisionerKit
import SwiftUI

/// The toolbar's sign-in status, which is also the way to sign in or out.
struct AccountStatus: View {
    let session: ViamSession
    let organizations: OrganizationsModel
    let environments: EnvironmentsModel
    @State private var confirmingSignOut = false

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .cliMissing:
                Link(destination: SignInView.installURL) {
                    Label("viam CLI not installed", systemImage: "circle.fill").foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            case .signedOut:
                SignInButton(session: session)
            case .failed:
                Button {
                    Task { await session.load() }
                } label: {
                    Label {
                        Text("Viam: Try Again")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(.orange)
                    }
                    .labelStyle(.titleAndIcon)
                }
            case .signingIn(let code):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(code.map { "Signing in… code \($0)" } ?? "Signing in…")
                    Button("Cancel") { session.cancelSignIn() }
                }
            case .signedIn(let account):
                Menu {
                    Button("Sign Out…") { confirmingSignOut = true }
                } label: {
                    Label {
                        Text(title(account))
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(.green)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .menuIndicator(.visible)
                .fixedSize()
            }
        }
        .help(help)
        .confirmationDialog("Sign out of Viam?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also signs you out of the viam CLI in Terminal.")
        }
    }

    private func title(_ account: ViamSession.Account) -> String {
        switch account {
        case .user(let email?): "Signed in as \(email)"
        case .user(nil): "Signed in to Viam"
        case .apiKey(let id): ["API key \(id.prefix(8))…", scope?.description].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// What the key reaches, once its organizations, and a single org's locations, are known.
    private var scope: KeyScope? {
        guard organizations.state == .loaded else { return nil }
        let orgs = organizations.rows
        guard orgs.count == 1 else { return KeyScope(organizations: orgs, locations: nil, grantsOnly: false) }
        guard case .loaded(let locations) = environments.locations(org: orgs[0].id) else { return nil }
        return KeyScope(organizations: orgs, locations: locations,
                        grantsOnly: environments.locationsAreGrantsOnly(org: orgs[0].id))
    }

    private var help: String {
        switch session.state {
        case .signedIn(.apiKey(let id)): "Signed in with the viam CLI's API key \(id)."
        case .failed(let message): message
        case .cliMissing: "The app signs in through the viam CLI. Click to see how to install it."
        default: ""
        }
    }
}

/// Runs `viam login`, which opens the browser.
struct SignInButton: View {
    let session: ViamSession

    var body: some View {
        Button {
            Task { await session.signIn() }
        } label: {
            Label {
                Text("Sign in to Viam")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
