import CryptoKit
import Foundation

extension Environment {
    /// One problem per broken rule, in the editor's field order. `otherNames` are
    /// the other environments' names. Rules that need a secret's value are
    /// skipped when `secrets` is nil.
    public func problems(otherNames: [String], secrets: EnvironmentSecrets? = nil) -> [EnvironmentProblem] {
        var problems: [EnvironmentProblem] = []
        func add(_ field: EnvironmentField, _ message: String) {
            problems.append(EnvironmentProblem(field: field, message: message))
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            add(.name, "Enter a name for the environment.")
        } else if otherNames.contains(where: { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            add(.name, "Another environment is already named \"\(trimmedName)\".")
        }

        if provisionMode == .full {
            if orgID?.isEmpty ?? true { add(.org, "Choose an organization.") }
            if locationID?.isEmpty ?? true { add(.location, "Choose a location.") }
        }

        if namePrefix.isEmpty {
            add(.namePrefix, "Enter a name prefix.")
        } else {
            for problem in MachineName.prefixProblems(namePrefix) { add(.namePrefix, problem) }
        }

        if username == "root" {
            add(.username, "The machines' account can't be root; choose another username.")
        } else if username.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) == nil {
            add(.username, "Usernames are lowercase letters, digits, _ and -, starting with a letter or _, up to 32 characters.")
        }

        if !hasPassword { add(.password, "Enter a password for the machines' account.") }

        if case .failure(let problem) = SSHPublicKey.parse(sshPublicKey) { add(.sshPublicKey, problem.message) }

        if TimeZone(identifier: timezone) == nil || !TimeZone.knownTimeZoneIdentifiers.contains(timezone) {
            add(.timezone, "\"\(timezone)\" isn't a known time zone.")
        }

        let ssid = wifiSSID ?? ""
        if ssid.utf8.count > 32 { add(.wifiSSID, "WiFi network names are at most 32 bytes.") }
        if hasWifiPassword && ssid.isEmpty {
            add(.wifiPassword, "Enter the network name, or clear the password.")
        } else if let password = secrets?.wifiPassword, !password.isEmpty, !Self.isWPAPassphrase(password) {
            add(.wifiPassword, "WiFi passwords are 8 to 63 characters.")
        }

        if robotNetEnabled {
            if let problem = RobotNetwork.addressProblem(robotNetAddress) { add(.robotNetAddress, problem) }
            if let port = robotNetPort, !port.isEmpty, let problem = RobotNetwork.portProblem(port) { add(.robotNetPort, problem) }
        }

        var seen: Set<String> = []
        for (index, package) in packages.enumerated() {
            let line = index + 1
            if package.wholeMatch(of: /[a-z0-9][a-z0-9+.\-]+/) == nil {
                add(.packages, "Line \(line): \"\(package)\" isn't an apt package name; names are lowercase letters, digits, + - and ., at least 2 characters.")
            } else if !seen.insert(package).inserted {
                add(.packages, "Line \(line) repeats \(package).")
            }
        }

        return problems
    }

    /// A WPA2 passphrase (8 to 63 bytes) or a raw 256-bit key (64 hex digits).
    static func isWPAPassphrase(_ password: String) -> Bool {
        (8...63).contains(password.utf8.count) || (password.count == 64 && password.allSatisfy(\.isHexDigit))
    }

    /// The settings a provision request carries. Throws when the environment has
    /// problems or its password hash isn't stored.
    public func config(secrets: EnvironmentSecrets) throws(EnvironmentError) -> EnvironmentConfig {
        var problems = problems(otherNames: [], secrets: secrets)
        if secrets.passwordHash?.isEmpty ?? true, !problems.contains(where: { $0.field == .password }) {
            problems.append(EnvironmentProblem(field: .password, message: "Enter a password for the machines' account."))
        }
        guard problems.isEmpty, let passwordHash = secrets.passwordHash else { throw .invalid(problems) }
        let wifi = wifiSSID.flatMap { ssid in
            ssid.isEmpty ? nil : EnvironmentConfig.Wifi(
                ssid: ssid, password: secrets.wifiPassword.flatMap { $0.isEmpty ? nil : $0 }, country: wifiCountry)
        }
        return EnvironmentConfig(
            provisionMode: provisionMode, username: username, passwordHash: passwordHash,
            sshPublicKey: sshPublicKey.trimmingCharacters(in: .whitespacesAndNewlines), timezone: timezone,
            packages: packages, wifi: wifi, tailscaleAuthKey: secrets.tailscaleAuthKey.flatMap { $0.isEmpty ? nil : $0 },
            robotNetAddress: robotNetEnabled ? robotNetAddress : RobotNetwork.none,
            robotNetPort: robotNetEnabled ? robotNetPort.flatMap { $0.isEmpty ? nil : $0 } : nil
        )
    }
}

public enum SSHKeyProblem: Error, Sendable, Equatable {
    case empty
    case privateKey
    case notPublicKey

    public var message: String {
        switch self {
        case .empty: "Choose an SSH public key so you can log in to the machines."
        case .privateKey: "That's a private key. Choose the matching .pub file."
        case .notPublicKey: "This isn't an OpenSSH public key."
        }
    }
}

/// One line of an OpenSSH `.pub` file: `<type> <base64 blob> [comment]`.
public struct SSHPublicKey: Sendable, Equatable {
    public static let types: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    public let type: String
    public let comment: String?
    /// As `ssh-keygen -l` prints it: `SHA256:` and the unpadded base64 digest of the blob.
    public let fingerprint: String

    public static func parse(_ text: String) -> Result<SSHPublicKey, SSHKeyProblem> {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .failure(.empty) }
        if line.hasPrefix("-----BEGIN") { return .failure(.privateKey) }
        guard !line.contains(where: \.isNewline) else { return .failure(.notPublicKey) }
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, types.contains(String(fields[0])),
              let blob = Data(base64Encoded: String(fields[1])), blobType(blob) == String(fields[0])
        else { return .failure(.notPublicKey) }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let comment = fields.count == 3 ? String(fields[2]) : nil
        return .success(SSHPublicKey(type: String(fields[0]), comment: comment, fingerprint: "SHA256:\(digest)"))
    }

    /// The key type the blob names in its first length-prefixed string.
    private static func blobType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, bytes.count >= 4 + length else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }
}
