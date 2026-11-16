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

/// One problem per field of `environment` that can't be rendered into an
/// installer config. Field names are the JSON keys. Every value lands in YAML
/// or shell, so no field may hold a control character or line break.
func environmentProblems(_ environment: Components.Schemas.Environment) -> [(field: String, message: String)] {
    var problems: [(field: String, message: String)] = []
    func check(_ field: String, _ value: String?, _ rule: (String) -> String?) {
        guard let value else { return }
        if hasControlCharacters(value) {
            problems.append((field, "must not contain control characters or line breaks"))
        } else if let message = rule(value) {
            problems.append((field, message))
        }
    }
    let any: (String) -> String? = { _ in nil }
    check("username", environment.username) {
        $0.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) == nil
            ? "must be lowercase letters, digits, _ and -, starting with a letter or _, up to 32 characters" : nil
    }
    check("password_hash", environment.passwordHash, any)
    check("ssh_public_key", environment.sshPublicKey, any)
    check("timezone", environment.timezone) {
        $0.wholeMatch(of: /[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*/) == nil ? "must be an IANA time zone name" : nil
    }
    if let packages = environment.packages {
        let bad = packages.filter { hasControlCharacters($0) || $0.wholeMatch(of: /[a-z0-9][a-z0-9+.\-]+/) == nil }
        if !bad.isEmpty { problems.append(("packages", "not apt package names: \(bad.count) of \(packages.count)")) }
    }
    check("wifi.ssid", environment.wifi?.ssid, any)
    check("wifi.password", environment.wifi?.password, any)
    check("tailscale_auth_key", environment.tailscaleAuthKey, any)
    check("robot_net_address", environment.robotNetAddress) {
        $0 == "none" || isPrivateAddressWithPrefix($0) ? nil
            : "must be none or a private address with its prefix, in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16"
    }
    check("robot_net_port", environment.robotNetPort) {
        $0.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\-]{0,14}/) == nil
            ? "must be up to 15 letters, digits, ., _ and -, starting with a letter or digit" : nil
    }
    return problems
}

/// A host, with an optional port, safe to render into the installer config.
func validServerHost(_ host: String) -> Bool {
    host.wholeMatch(of: /[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?/) != nil
}

func hasControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains {
        switch $0.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}

/// The rules of `scripts/lib/robot-net.sh`: an RFC 1918 address with a prefix.
private func isPrivateAddressWithPrefix(_ address: String) -> Bool {
    guard let match = address.wholeMatch(
        of: /(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\/(?:0|[1-9]|[12][0-9]|3[0-2])/)
    else { return false }
    let octets = [match.1, match.2, match.3, match.4].compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
    let (a, b) = (octets[0], octets[1])
    return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
}
