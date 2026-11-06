import Foundation

/// The OS image PXE machines download from `/pxe/{name}/{fileName}`.
struct BootImage: Sendable {
    let url: URL
    let fileName: String
    let osName: String

    init(files: URL, path: String) throws {
        url = files.appending(path: path)
        fileName = url.lastPathComponent
        osName = ProvisionerServer.osName(forImageNamed: fileName)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConfigurationError(description: "boot image \(path) is not readable")
        }
    }
}

/// `Ubuntu 24.04.4` for `ubuntu-24.04.4-live-server-amd64.iso`; the name without
/// its extension when it doesn't start `<distro>-<version>`.
func osName(forImageNamed name: String) -> String {
    let parts = name.split(separator: "-", maxSplits: 2)
    if parts.count == 3, let distro = parts.first, distro.allSatisfy(\.isLetter),
       parts[1].first?.isNumber == true, parts[1].allSatisfy({ $0.isNumber || $0 == "." }) {
        return distro.prefix(1).uppercased() + distro.dropFirst() + " " + parts[1]
    }
    let stem = (name as NSString).deletingPathExtension
    return stem.isEmpty ? name : stem
}
