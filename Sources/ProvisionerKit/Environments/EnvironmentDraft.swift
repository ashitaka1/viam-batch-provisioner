import Foundation

/// An environment being edited: its settings, with the packages as typed.
public struct EnvironmentDraft: Equatable, Sendable {
    /// The settings; its `packages` are ignored in favour of `packagesText`.
    public var environment: Environment
    /// One package per line.
    public var packagesText: String

    public init(_ stored: Environment) {
        environment = stored
        packagesText = stored.packages.joined(separator: "\n")
    }

    /// The settings to save: the packages read from the text, blank lines dropped.
    public var value: Environment {
        var value = environment
        value.packages = packagesText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return value
    }

    /// The stored copy went from `old` to `new`: undo, redo, a rename or a secret
    /// change. Each field the draft still holds as `old` takes `new`'s value; an
    /// unsaved edit is kept. The packages text counts as edited when it differs
    /// from `old`'s as typed, so a blank line still being typed is kept.
    public mutating func storedChanged(from old: Environment, to new: Environment) {
        let keepsPackages = packagesText != EnvironmentDraft(old).packagesText
        environment = Self.merge(environment, old: old, new: new) ?? new
        environment.packages = new.packages
        if !keepsPackages { packagesText = EnvironmentDraft(new).packagesText }
    }

    /// Merges field by field through the Codable form, so a field added to
    /// `Environment` merges with no change here. An optional that is nil has no
    /// key, which compares as `NSNull`. Nil when encoding or decoding fails.
    private static func merge(_ draft: Environment, old: Environment, new: Environment) -> Environment? {
        func fields(_ environment: Environment) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(environment) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard var merged = fields(draft), let oldFields = fields(old), let newFields = fields(new) else { return nil }
        for key in Set(merged.keys).union(oldFields.keys).union(newFields.keys) {
            let drafted = merged[key] as? NSObject ?? NSNull()
            if drafted.isEqual(oldFields[key] as? NSObject ?? NSNull()) { merged[key] = newFields[key] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Environment.self, from: data)
    }
}
