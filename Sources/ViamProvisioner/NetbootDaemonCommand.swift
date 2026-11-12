import Foundation
import ServiceManagement

/// The `ProvisionerNetboot` launch daemon the app bundle carries in `Contents/Library/LaunchDaemons`.
enum NetbootDaemon {
    static var service: SMAppService { .daemon(plistName: "com.bringingfire.viam-provisioner.netboot.plist") }

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

/// `ViamProvisioner --netboot-daemon register|unregister|status`: registers the netboot daemon from the
/// app's own process, which SMAppService requires, and exits before any window opens.
enum NetbootDaemonCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--netboot-daemon") else { return }
        let action = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        let service = NetbootDaemon.service
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
                fail("--netboot-daemon takes register, unregister or status.")
            }
        } catch {
            fail("netboot daemon \(action) failed: \(error.localizedDescription) (\((error as NSError).code))")
        }
        print("netboot daemon: \(NetbootDaemon.describe(service.status))")
        exit(0)
    }

    private static func unregister() throws {
        let result = Locked<Result<Void, any Error>>(.success(()))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do { try await NetbootDaemon.service.unregister() } catch { result.set(.failure(error)) }
        }
        done.wait()
        try result.get().get()
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
