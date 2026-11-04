import ProvisionerAPI

/// One sentence per Viam machine-name rule `name` breaks; empty when valid.
/// Mirrors `name_problems` in pxe-watcher/provisioner_service.py.
func nameProblems(_ name: String) -> [String] {
    guard let first = name.first else { return ["Machine name is empty."] }
    func allowed(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
    var problems: [String] = []
    if !(allowed(first) && first != "-") {
        problems.append(#""\#(name)" starts with "\#(first)"; Viam machine names start with a letter or digit."#)
    }
    if name.count > 1 && name.hasSuffix("-") {
        problems.append(#""\#(name)" ends with "-"; a machine name becomes its hostname, which can't end with a hyphen."#)
    }
    if name.count > maxNameLength {
        problems.append(#""\#(name)" is \#(name.count) characters; Viam machine names are at most \#(maxNameLength)."#)
    }
    var bad: [Character] = []
    for c in name where !allowed(c) && !bad.contains(c) {
        bad.append(c)
    }
    if !bad.isEmpty {
        let listed = bad.map { #""\#($0)""# }.joined(separator: ", ")
        problems.append(#""\#(name)" contains \#(listed); Viam machine names contain only letters, digits and hyphens."#)
    }
    return problems
}

let maxNameLength = 60
let maxProvisionItems = 500

func validCredentials(_ credentials: Components.Schemas.ViamCredentials) -> Bool {
    !credentials.cloud.id.isEmpty && !credentials.cloud.secret.isEmpty
}
