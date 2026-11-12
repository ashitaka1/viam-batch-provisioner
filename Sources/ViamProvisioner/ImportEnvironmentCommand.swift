import Foundation
import ProvisionerKit

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
                print("Add a Viam API key in the app to use its organization \(environment.orgID ?? "(none)").")
            }
            exit(0)
        } catch {
            fail("Couldn't import \(file.path): \(error.localizedDescription)")
        }
    }

    /// The org's name as a stored API key records it; nil when no key reaches the org.
    private static func orgName(_ orgID: String) -> String? {
        (try? KeychainAPIKeyStore().all())?.keys.first { $0.scope.orgID == orgID }?.scope.orgName
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
