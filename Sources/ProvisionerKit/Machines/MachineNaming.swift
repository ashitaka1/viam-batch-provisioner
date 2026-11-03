public import Foundation

/// Viam's machine-name rule, from validateMachineName in the Viam app. Viam
/// doesn't document it, so every rejection names the rule that was broken, in
/// the same words as the provisioner API.
public enum MachineName {
    public static let maxLength = 60

    /// One sentence per rule `name` breaks; empty when Viam accepts it.
    public static func problems(_ name: String) -> [String] {
        guard let first = name.first else { return ["Machine name is empty."] }
        var problems: [String] = []
        if !isAlphanumeric(first) {
            problems.append("\"\(name)\" starts with \"\(first)\"; Viam machine names start with a letter or digit.")
        }
        let length = name.unicodeScalars.count
        if length > maxLength {
            problems.append("\"\(name)\" is \(length) characters; Viam machine names are at most \(maxLength).")
        }
        var disallowed: [Character] = []
        for character in name where !isAlphanumeric(character) && character != "-" && !disallowed.contains(character) {
            disallowed.append(character)
        }
        if !disallowed.isEmpty {
            let listed = disallowed.map { "\"\($0)\"" }.joined(separator: ", ")
            problems.append("\"\(name)\" contains \(listed); Viam machine names contain only letters, digits and hyphens.")
        }
        return problems
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

public enum MachineNamingError: Error, Sendable, Equatable, LocalizedError {
    case invalidCount(Int)
    case invalidName(String, problems: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidCount(let count): "Machine count must be at least 1; got \(count)."
        case .invalidName(_, let problems): problems.joined(separator: " ")
        }
    }
}

/// Picks batch names the way scripts/provision-batch.sh does: `<prefix>-<N>`,
/// filling gaps in the location's numbers first, then counting past the highest,
/// skipping names already queued on the server.
public enum MachineNaming {
    /// The checks that need no knowledge of the location: the count, and the
    /// prefix's characters as they appear in its first name.
    public static func check(prefix: String, count: Int) throws(MachineNamingError) {
        guard count >= 1 else { throw .invalidCount(count) }
        let first = "\(prefix)-1"
        let problems = MachineName.problems(first)
        guard problems.isEmpty else { throw .invalidName(first, problems: problems) }
    }

    public static func names(prefix: String, count: Int, existing: [String], queued: Set<String>) throws(MachineNamingError) -> [String] {
        try check(prefix: prefix, count: count)

        let lowered = prefix.lowercased() + "-"
        var taken = Set<Int>()
        for name in existing {
            let name = name.lowercased()
            guard name.hasPrefix(lowered) else { continue }
            let digits = name.dropFirst(lowered.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { continue }
            taken.insert(number)
        }
        let queued = Set(queued.map { $0.lowercased() })

        var names: [String] = []
        var number = 1
        while names.count < count {
            let name = "\(prefix)-\(number)"
            if !taken.contains(number) && !queued.contains(name.lowercased()) {
                let problems = MachineName.problems(name)
                guard problems.isEmpty else { throw .invalidName(name, problems: problems) }
                names.append(name)
            }
            number += 1
        }
        return names
    }
}
