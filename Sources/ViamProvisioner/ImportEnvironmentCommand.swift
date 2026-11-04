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
            if let orgID = environment.orgID,
               let credential = try? KeychainOrgCredentialStore().all().first(where: { $0.orgID == orgID }) {
                environment.orgName = credential.orgName
                try store.save(environment, secrets: nil)
            }
            print("Imported \(environment.name) into the app.")
            if environment.provisionMode == .full, environment.orgName == nil {
                print("Its organization \(environment.orgID ?? "(none)") isn't paired; run `just pair-app` for it.")
            }
            exit(0)
        } catch {
            fail("Couldn't import \(file.path): \(error.localizedDescription)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
