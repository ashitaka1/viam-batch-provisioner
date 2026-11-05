import Foundation
import ProvisionerHelperXPC

/// Writes and removes files the peer sends, confined to the TFTP root: a path may not climb out
/// with `..`, nor through a symlink inside the root. Only regular files are removed.
public struct TFTPRootFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The file's URL, or `invalidPath` for an absolute path or one with an empty, `.` or `..` component.
    public func url(for path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw HelperError.invalidPath(path) }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    public func write(_ contents: Data, to path: String) throws {
        let url = try url(for: path)
        try requireInsideRoot(url, path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, options: .atomic)
        } catch let error as HelperError {
            throw error
        } catch {
            throw HelperError.writeFailed("\(path): \(error.localizedDescription)")
        }
    }

    public func remove(_ path: String) throws {
        let url = try url(for: path)
        try requireInsideRoot(url, path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return
        } catch {
            throw HelperError.writeFailed("\(path): \(error.localizedDescription)")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HelperError.writeFailed("\(path): not a regular file")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HelperError.writeFailed("\(path): \(error.localizedDescription)")
        }
    }

    /// `invalidPath` when the file's directory lies outside the root once the symlinks in its
    /// deepest existing ancestor are resolved, before anything is created there.
    private func requireInsideRoot(_ url: URL, _ path: String) throws {
        let rootComponents = Self.resolved(root).pathComponents
        guard Self.resolved(url.deletingLastPathComponent()).pathComponents.starts(with: rootComponents)
        else { throw HelperError.invalidPath(path) }
    }

    /// `url` with symlinks resolved in its deepest existing ancestor, the missing rest appended.
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }
}
