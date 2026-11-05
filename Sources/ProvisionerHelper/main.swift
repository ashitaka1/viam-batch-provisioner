import Dispatch
import Foundation
import ProvisionerHelperCore
import ProvisionerHelperXPC

// The root launch daemon `com.bringingfire.viam-provisioner.helper`, registered by the app with
// SMAppService. It serves only when a peer asks, so it binds nothing until ProvisionerServer
// (or provisioner-helperctl) connects.

let defaultRoot = "/Library/Application Support/Viam Provisioner/TFTP"

var arguments = CommandLine.arguments.dropFirst()
var rootPath = defaultRoot
while let flag = arguments.popFirst() {
    guard flag == "--root", let value = arguments.popFirst() else {
        FileHandle.standardError.write(Data("usage: ProvisionerHelper [--root <dir>]\n".utf8))
        exit(2)
    }
    rootPath = value
}

let root = URL(fileURLWithPath: rootPath, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("ProvisionerHelper: cannot create \(rootPath): \(error)\n".utf8))
    exit(1)
}

let service = HelperService(root: root)
let listener = NSXPCListener(machServiceName: ProvisionerHelperXPC.machServiceName)
listener.setConnectionCodeSigningRequirement(PeerRequirement.requirement(teamIdentifier: PeerRequirement.currentTeamIdentifier()))
listener.delegate = service
listener.resume()

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler {
    Task {
        await service.shutdown()
        exit(0)
    }
}
terminate.resume()

dispatchMain()
