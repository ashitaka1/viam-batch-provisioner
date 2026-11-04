import ProvisionerKit
import SwiftUI

/// The detail pane while the app can't act on Viam.
struct SignInView: View {
    static let installURL = URL(string: "https://docs.viam.com/cli/")!

    let session: ViamSession

    var body: some View {
        VStack(spacing: 14) {
            switch session.state {
            case .cliMissing:
                Text("Install the viam CLI").font(.title2.bold())
                Text("The app signs in to Viam through the viam CLI.")
                    .foregroundStyle(.secondary)
                Link("How to install the viam CLI", destination: Self.installURL)
                Button("Check Again") { Task { await session.load() } }
            case .signingIn(let code):
                Text("Signing in to Viam").font(.title2.bold())
                if let code {
                    Text("Check that your browser shows this code:").foregroundStyle(.secondary)
                    Text(code).font(.system(.largeTitle, design: .monospaced).bold()).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.").foregroundStyle(.secondary)
                }
                Button("Cancel") { session.cancelSignIn() }
            case .failed(let message):
                Text("Sign in to Viam").font(.title2.bold())
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Try Again") { Task { await session.load() } }.buttonStyle(.borderedProminent)
            default:
                Text("Sign in to Viam").font(.title2.bold())
                Text("Your browser opens to sign in. The app then uses your Viam account's organizations.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                SignInButton(session: session).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}
