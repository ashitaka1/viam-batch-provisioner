import Foundation

/// The directory TFTP serves. Requests resolve to regular files inside it, after following symlinks.
struct TFTPRoot: Sendable {
    let url: URL
    private let rootComponents: [String]

    init(_ url: URL) {
        self.url = url
        rootComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    func resolve(_ filename: String) -> URL? {
        let relative = filename.drop { $0 == "/" }
        guard !relative.isEmpty else { return nil }
        let candidate = url.appendingPathComponent(String(relative)).standardizedFileURL.resolvingSymlinksInPath()
        let components = candidate.pathComponents
        guard components.count > rootComponents.count,
              components.starts(with: rootComponents)
        else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return candidate
    }
}
