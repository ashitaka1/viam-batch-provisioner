import Foundation

/// The hidden account the server daemon runs as, its directory, and the shell scripts the app runs
/// with administrator authorization to create and remove them (docs/decisions/0050).
public enum ServerAccount {
    public static let name = "_viamprovisioner"
    public static let label = "com.bringingfire.viam-provisioner.server"
    public static let serverDirectory = URL(filePath: "/Library/Application Support/Viam Provisioner/Server", directoryHint: .isDirectory)
    public static let dataDirectory = serverDirectory.appending(path: "data", directoryHint: .isDirectory)
    public static let filesDirectory = serverDirectory.appending(path: "files", directoryHint: .isDirectory)
    /// Apple allocates its own daemon accounts upward from 200, so the account takes the highest free ID here.
    static let idRange = 401...499

    /// Creates the account when it is missing, with the highest ID in `idRange` free as both a user and
    /// a group ID, then creates the server directory and its `data` and `files`, private to the account.
    public static func createScript() -> String {
        createScript(dscl: "/usr/bin/dscl", chown: "/usr/sbin/chown", serverDirectory: serverDirectory)
    }

    /// Deletes the server directory and the account.
    public static func removeScript() -> String {
        removeScript(dscl: "/usr/bin/dscl", serverDirectory: serverDirectory)
    }

    /// Whether the server directory exists and belongs to the account. Its `data` and `files` can't be checked:
    /// the directory is private to the account, so the operator running the app can't see inside it.
    public static func isSetUp(directory: URL = serverDirectory, ownerName: String = name,
                               fileManager: FileManager = .default) -> Bool {
        (try? fileManager.attributesOfItem(atPath: directory.path)[.ownerAccountName] as? String) == ownerName
    }

    /// The first directory on the way to `binary`, or `binary` itself, that the account can't pass through or
    /// run, judged by each one's permission bits for other users; nil when it can reach and run the binary.
    /// The account is in no group the operator's files carry, so the bits for other users are the ones that apply.
    public static func unreachablePath(to binary: URL, below base: URL = URL(filePath: "/")) -> URL? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let components = binary.standardizedFileURL.pathComponents
        guard components.starts(with: baseComponents) else { return binary }
        var url = base.standardizedFileURL
        for component in components.dropFirst(baseComponents.count) {
            url.append(path: component)
            guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue,
                  mode & 0o001 != 0
            else { return url }
        }
        return nil
    }

    /// Other users and groups holding the account's ID, which can read and change the server's data.
    public struct IDConflict: Equatable, Sendable {
        public let id: Int
        public let users: [String]
        public let groups: [String]

        public init(id: Int, users: [String], groups: [String]) {
            self.id = id
            self.users = users
            self.groups = groups
        }

        public var message: String {
            let names = users.map { "user \($0)" } + groups.map { "group \($0)" }
            return "Another account shares \(ServerAccount.name)'s ID \(id): \(names.joined(separator: ", ")). It can read and change the server's data."
        }
    }

    /// The conflict in `dscl . -list /Users UniqueID` and `dscl . -list /Groups PrimaryGroupID` output, if any.
    static func conflict(users: String, groups: String) -> IDConflict? {
        func records(_ text: String) -> [(name: String, id: Int)] {
            text.split(separator: "\n").compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, let id = Int(fields[fields.count - 1]) else { return nil }
                return (String(fields[0]), id)
            }
        }
        let userRecords = records(users), groupRecords = records(groups)
        guard let id = userRecords.first(where: { $0.name == name })?.id else { return nil }
        let otherUsers = userRecords.filter { $0.id == id && $0.name != name }.map(\.name)
        let otherGroups = groupRecords.filter { $0.id == id && $0.name != name }.map(\.name)
        guard !otherUsers.isEmpty || !otherGroups.isEmpty else { return nil }
        return IDConflict(id: id, users: otherUsers, groups: otherGroups)
    }

    /// Reads the local directory for a conflict. Needs no privileges.
    public static func currentConflict() -> IDConflict? {
        func list(_ arguments: [String]) -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/dscl")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        return conflict(users: list([".", "-list", "/Users", "UniqueID"]), groups: list([".", "-list", "/Groups", "PrimaryGroupID"]))
    }

    static func createScript(dscl: String, chown: String, serverDirectory: URL) -> String {
        let user = "/Users/\(name)", group = "/Groups/\(name)"
        return """
            set -e
            dscl=\(quoted(dscl)); dir=\(quoted(serverDirectory.path))
            id=$("$dscl" . -read \(user) UniqueID 2>/dev/null | awk '/UniqueID:/ {print $2}')
            if [ -z "$id" ]; then
              used=$( { "$dscl" . -list /Users UniqueID; "$dscl" . -list /Groups PrimaryGroupID; } | awk '{print $NF}')
              n=\(idRange.upperBound)
              while [ "$n" -ge \(idRange.lowerBound) ]; do
                if ! printf '%s\\n' "$used" | grep -qx "$n"; then id=$n; break; fi
                n=$((n - 1))
              done
              if [ -z "$id" ]; then
                echo "No ID between \(idRange.lowerBound) and \(idRange.upperBound) is free for \(name)." >&2
                exit 1
              fi
              "$dscl" . -create \(group)
              "$dscl" . -create \(group) PrimaryGroupID "$id"
              "$dscl" . -create \(group) RealName 'Viam Provisioner Server'
              "$dscl" . -create \(user)
              "$dscl" . -create \(user) UniqueID "$id"
              "$dscl" . -create \(user) PrimaryGroupID "$id"
              "$dscl" . -create \(user) UserShell /usr/bin/false
              "$dscl" . -create \(user) NFSHomeDirectory /var/empty
              "$dscl" . -create \(user) RealName 'Viam Provisioner Server'
              "$dscl" . -create \(user) IsHidden 1
              "$dscl" . -create \(user) Password '*'
            fi
            mkdir -p "$dir/data" "$dir/files"
            chmod 700 "$dir" "$dir/data" "$dir/files"
            \(quoted(chown)) -R "$id:$id" "$dir"
            """
    }

    static func removeScript(dscl: String, serverDirectory: URL) -> String {
        """
        set -e
        dscl=\(quoted(dscl))
        rm -rf \(quoted(serverDirectory.path))
        if "$dscl" . -read /Users/\(name) >/dev/null 2>&1; then "$dscl" . -delete /Users/\(name); fi
        if "$dscl" . -read /Groups/\(name) >/dev/null 2>&1; then "$dscl" . -delete /Groups/\(name); fi
        """
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
