public import Foundation

/// The keys a QA guest loads at launch: a JSON array of
/// `{"key_id", "key", "organization_id" | "location_id"}` at the path in
/// `VIAM_PROVISIONER_KEYS_FILE`. Which ID an entry gives says whether the key is
/// an organization's or a location's.
public enum KeysFile {
    public static let environmentVariable = "VIAM_PROVISIONER_KEYS_FILE"

    public struct Entry: Equatable, Sendable, CustomStringConvertible {
        public var keyID: String?
        public var key: String?
        public var kind: APIKeyKind?
        public var scopeID: String?

        public init(keyID: String?, key: String?, kind: APIKeyKind?, scopeID: String?) {
            self.keyID = keyID
            self.key = key
            self.kind = kind
            self.scopeID = scopeID
        }

        public var description: String { "KeysFile.Entry(\(keyID ?? "no key_id"))" }
    }

    public struct Unreadable: Error, Equatable {}

    /// Every entry, including those missing a field, so each can be reported.
    /// Throws `Unreadable`, which quotes nothing, when the file isn't a JSON array of objects.
    public static func entries(_ data: Data) throws -> [Entry] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw Unreadable() }
        return try array.map { element in
            guard let object = element as? [String: Any] else { throw Unreadable() }
            func string(_ name: String) -> String? {
                (object[name] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            let (kind, scopeID): (APIKeyKind?, String?) =
                if let location = string("location_id") { (.location, location) }
                else if let org = string("organization_id") { (.organization, org) }
                else { (nil, nil) }
            return Entry(keyID: string("key_id"), key: string("key"), kind: kind, scopeID: scopeID)
        }
    }
}
