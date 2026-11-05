import Foundation
import ProvisionerHelperXPC
import Security

/// The code signing requirement a peer must meet to connect to the helper.
public enum PeerRequirement {
    /// A team-signed helper accepts peers signed by the same team. An ad-hoc helper, a
    /// development build, accepts the peer identifiers in `ProvisionerHelperXPC.peerIdentifiers`.
    public static func requirement(teamIdentifier: String?) -> String {
        if let teamIdentifier {
            return #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)""#
        }
        return ProvisionerHelperXPC.peerIdentifiers.map { #"identifier "\#($0)""# }.joined(separator: " or ")
    }

    /// Whether a peer may connect beyond the code signing requirement. An ad-hoc identifier proves
    /// nothing, so an ad-hoc helper also requires the peer to run as the user who owns the helper's
    /// executable: the developer who built and registered it.
    public static func acceptsPeer(teamIdentifier: String?, peerUID: uid_t, executableOwnerUID: uid_t?) -> Bool {
        teamIdentifier != nil || peerUID == executableOwnerUID
    }

    /// The owner of this process's executable file.
    public static func executableOwnerUID() -> uid_t? {
        guard let path = Bundle.main.executablePath, let owner = try? FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber
        else { return nil }
        return owner.uint32Value
    }

    /// The team that signed this process, nil when it is ad hoc or unsigned.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
