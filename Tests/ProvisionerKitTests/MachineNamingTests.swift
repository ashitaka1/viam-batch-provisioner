import Foundation
import ProvisionerKit
import Testing

private let charactersRule = "Viam machine names contain only letters, digits and hyphens."

@Test func fillsGapsThenPastHighest() throws {
    let names = try MachineNaming.names(prefix: "lab-pi", count: 4, existing: ["lab-pi-1", "lab-pi-3", "lab-pi-5"], queued: [])
    #expect(names == ["lab-pi-2", "lab-pi-4", "lab-pi-6", "lab-pi-7"])
}

@Test func emptyLocationStartsAtOne() throws {
    let names = try MachineNaming.names(prefix: "lab-pi", count: 2, existing: [], queued: [])
    #expect(names == ["lab-pi-1", "lab-pi-2"])
}

@Test func skipsQueuedNames() throws {
    let names = try MachineNaming.names(
        prefix: "lab-pi", count: 2, existing: ["lab-pi-1", "lab-pi-3"], queued: ["lab-pi-2", "lab-pi-4"])
    #expect(names == ["lab-pi-5", "lab-pi-6"])
}

@Test func matchesWholeNameCaseInsensitively() throws {
    let existing = ["Lab-Pi-2", "lab-pi-01", "lab-pi-2-old", "xlab-pi-3", "lab-pi", "lab-pi-"]
    #expect(try MachineNaming.names(prefix: "lab-pi", count: 2, existing: existing, queued: []) == ["lab-pi-3", "lab-pi-4"])
    #expect(try MachineNaming.names(prefix: "lab-pi", count: 2, existing: existing, queued: ["LAB-PI-3"]) == ["lab-pi-4", "lab-pi-5"])
}

@Test func keepsPrefixCase() throws {
    #expect(try MachineNaming.names(prefix: "Lab-Pi", count: 1, existing: ["lab-pi-1"], queued: []) == ["Lab-Pi-2"])
}

/// Same cases and wording as the Python API's name_problems.
@Test func problemsMatchPythonWording() {
    #expect(MachineName.problems("lab_pi") == [#""lab_pi" contains "_"; "# + charactersRule])
    #expect(MachineName.problems("-lab pi.") == [
        #""-lab pi." starts with "-"; Viam machine names start with a letter or digit."#,
        #""-lab pi." contains " ", "."; "# + charactersRule,
    ])
    let long = String(repeating: "a", count: 61)
    #expect(MachineName.problems(long) == ["\"\(long)\" is 61 characters; Viam machine names are at most 60."])
    #expect(MachineName.problems("") == ["Machine name is empty."])
    #expect(MachineName.problems("lab-") == [])
    #expect(MachineName.problems("Lab-Pi-1") == [])
    #expect(MachineName.problems("café") == [#""café" contains "é"; "# + charactersRule])
    #expect(MachineName.problems("a__b") == [#""a__b" contains "_"; "# + charactersRule])
    #expect(MachineName.problems("é-lab") == [
        #""é-lab" starts with "é"; Viam machine names start with a letter or digit."#,
        #""é-lab" contains "é"; "# + charactersRule,
    ])
}

@Test func lengthCountsCodePoints() {
    let name = String(repeating: "é", count: 30) + String(repeating: "a", count: 30)
    #expect(MachineName.problems(name).contains { $0.contains("is 60 characters") } == false)
    let longer = name + "é"
    #expect(MachineName.problems(longer).contains { $0.contains("is 61 characters") })
}

@Test func rejectsInvalidPrefix() throws {
    #expect(throws: MachineNamingError.invalidName("lab_pi-1", problems: [#""lab_pi-1" contains "_"; "# + charactersRule])) {
        try MachineNaming.names(prefix: "lab_pi", count: 1, existing: [], queued: [])
    }

    let prefix = String(repeating: "a", count: 58)
    #expect(try MachineNaming.names(prefix: prefix, count: 1, existing: [], queued: []) == ["\(prefix)-1"])
    let taken = (1...9).map { "\(prefix)-\($0)" }
    let thrown = #expect(throws: MachineNamingError.self) {
        try MachineNaming.names(prefix: prefix, count: 1, existing: taken, queued: [])
    }
    let sentence = "\"\(prefix)-10\" is 61 characters; Viam machine names are at most 60."
    #expect(thrown == .invalidName("\(prefix)-10", problems: [sentence]))
    #expect(thrown?.errorDescription == sentence)
}

@Test func rejectsNonPositiveCount() {
    let zero = #expect(throws: MachineNamingError.self) {
        try MachineNaming.names(prefix: "lab-pi", count: 0, existing: [], queued: [])
    }
    #expect(zero == .invalidCount(0))
    #expect(zero?.errorDescription == "Machine count must be at least 1; got 0.")
    #expect(throws: MachineNamingError.invalidCount(-1)) {
        try MachineNaming.names(prefix: "lab-pi", count: -1, existing: [], queued: [])
    }
}
