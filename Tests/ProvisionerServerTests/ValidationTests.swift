@testable import ProvisionerServer
import Testing

@Test(arguments: [
    ("robot-1", 0), ("a", 0), ("A1-b2", 0), (String(repeating: "a", count: 60), 0),
    ("", 1), ("-", 1), ("-a", 1), ("a-", 1), ("a b", 1), ("café", 1), ("a_b", 1),
    (String(repeating: "a", count: 61), 1), ("-a b-", 3),
])
func nameRule(name: String, problemCount: Int) {
    #expect(nameProblems(name).count == problemCount, "\(name): \(nameProblems(name))")
}
