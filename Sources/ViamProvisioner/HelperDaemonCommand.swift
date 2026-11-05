import Foundation
import ServiceManagement

/// The `ProvisionerHelper` launch daemon the app bundle carries in `Contents/Library/LaunchDaemons`.
enum HelperDaemon {
    static var service: SMAppService { .daemon(plistName: "com.bringingfire.viam-provisioner.helper.plist") }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "registered; allow it in System Settings > General > Login Items & Extensions"
        case .notFound: "not registered, or missing from the app bundle"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}

/// `ViamProvisioner --helper-daemon register|unregister|status`: registers the helper from the
/// app's own process, which SMAppService requires, and exits before any window opens.
enum HelperDaemonCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--helper-daemon") else { return }
        let action = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        let service = HelperDaemon.service
        do {
            switch action {
            case "register":
                // register() throws "Operation not permitted" when the daemon awaits approval.
                do { try service.register() } catch where service.status == .requiresApproval {}
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            case "unregister":
                try unregister()
            case "status":
                break
            default:
                fail("--helper-daemon takes register, unregister or status.")
            }
        } catch {
            fail("helper daemon \(action) failed: \(error.localizedDescription) (\((error as NSError).code))")
        }
        print("helper daemon: \(HelperDaemon.describe(service.status))")
        exit(0)
    }

    private static func unregister() throws {
        let result = Locked<Result<Void, any Error>>(.success(()))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do { try await HelperDaemon.service.unregister() } catch { result.set(.failure(error)) }
        }
        done.wait()
        try result.get().get()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
