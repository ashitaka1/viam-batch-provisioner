public import Foundation

/// The public keys in a directory such as `~/.ssh`, for the editor's key menu.
public enum SSHKeyDirectory {
    public struct Entry: Sendable, Equatable {
        public let file: URL
        /// The key line, without its trailing newline.
        public let text: String
        public let key: SSHPublicKey
    }

    /// Every `*.pub` file that holds one OpenSSH public key, sorted by file name.
    /// A missing or unreadable directory has none.
    public static func keys(in directory: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let raw = try? String(contentsOf: file, encoding: .utf8), case .success(let key) = SSHPublicKey.parse(raw)
                else { return nil }
                return Entry(file: file, text: raw.trimmingCharacters(in: .whitespacesAndNewlines), key: key)
            }
    }
}
