import Foundation
import ProvisionerHelperXPC

/// Writes and removes files the peer sends, confined to the TFTP root.
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
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, options: .atomic)
        } catch {
            throw HelperError.writeFailed("\(path): \(error.localizedDescription)")
        }
    }

    public func remove(_ path: String) throws {
        let url = try url(for: path)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw HelperError.writeFailed("\(path): \(error.localizedDescription)")
        }
    }
}
