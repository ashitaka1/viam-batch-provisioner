import Foundation
import ProvisionerKit
import ViamAPI

/// `ViamProvisioner --import-environment <path>`: the developer import behind
/// `just import-env`. It runs in the app's own process, so the Keychain items
/// it writes belong to the app, and exits before any window opens.
enum ImportEnvironmentCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--import-environment") else { return }
        guard arguments.indices.contains(flag + 1) else { fail("--import-environment needs the path of a .env file.") }
        let file = URL(filePath: arguments[flag + 1])
        do {
            let store = FileEnvironmentStore()
            var environment = try SiteEnvImport.importFile(at: file, into: store)
            if let orgID = environment.orgID, let name = orgName(orgID) {
                environment.orgName = name
                try store.save(environment, secrets: nil)
            }
            print("Imported \(environment.name) into the app.")
            if environment.provisionMode == .full, environment.orgName == nil {
                print("Sign in to Viam in the app to use its organization \(environment.orgID ?? "(none)").")
            }
            exit(0)
        } catch {
            fail("Couldn't import \(file.path): \(error.localizedDescription)")
        }
    }

    /// The org's name as the viam CLI's login, a user's or an API key's, sees it; nil when signed out or not visible.
    private static func orgName(_ orgID: String) -> String? {
        let result = Locked<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let executable = await ViamCLI.locate() else { return }
            let cli = ViamCLI(run: ViamCLI.processRunner(executable: executable))
            let baseURL = CLIConfig.baseURL() ?? ViamAppClient.defaultBaseURL
            let tokens = CLILoginTokens(
                login: { CLIConfig.login() }, user: CLITokenSource(cli: { cli }),
                apiKey: APIKeyTokenSource(readKey: { CLIConfig.apiKey() },
                                          authenticate: { try await ViamAppClient.authenticate(keyID: $0, key: $1, baseURL: baseURL) }))
            let lister = ViamOrganizationLister(tokens: tokens, baseURL: baseURL)
            var name = (try? await lister.organizations())?.first { $0.id == orgID }?.name
            if name == nil { name = (try? await lister.organization(id: orgID))?.name }
            result.set(name)
        }
        done.wait()
        return result.get()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value { lock.withLock { value } }
}
