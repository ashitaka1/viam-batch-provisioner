import ProvisionerAPI

/// `templates/user-data.tpl`, compiled in through the symlink beside this file.
let userDataTemplate = String(decoding: PackageResources.user_data_tpl, as: UTF8.self)

/// gettext's `envsubst` with a variable list: `${NAME}` and `$NAME` are replaced
/// for the names in `values`, in one pass, and every other `$` is copied.
func envsubst(_ template: String, _ values: [String: String]) -> String {
    func isNameStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
    func isNameChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
    var out = ""
    var i = template.startIndex
    while i < template.endIndex {
        let c = template[i]
        let next = template.index(after: i)
        guard c == "$", next < template.endIndex else {
            out.append(c)
            i = next
            continue
        }
        if template[next] == "{" {
            let nameStart = template.index(after: next)
            let nameEnd = template[nameStart...].firstIndex { !isNameChar($0) } ?? template.endIndex
            if nameEnd < template.endIndex, template[nameEnd] == "}", let value = values[String(template[nameStart..<nameEnd])] {
                out += value
                i = template.index(after: nameEnd)
                continue
            }
        } else if isNameStart(template[next]) {
            let nameEnd = template[next...].firstIndex { !isNameChar($0) } ?? template.endIndex
            if let value = values[String(template[next..<nameEnd])] {
                out += value
                i = nameEnd
                continue
            }
        }
        out.append(c)
        i = next
    }
    return out
}

/// The text between YAML double quotes that reads back as `value`. Control
/// characters never reach here: provisioning refuses them.
func yamlQuoted(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// `value` as text in an unquoted shell heredoc, which expands `\`, `$` and backticks.
func heredocEscaped(_ value: String) -> String {
    var out = ""
    for c in value {
        if c == "\\" || c == "$" || c == "`" { out.append("\\") }
        out.append(c)
    }
    return out
}

/// The template rendered for one machine. The values go where the template puts
/// them: the password hash and SSH key in YAML double quotes, the WiFi settings
/// in double quotes inside the unquoted NETPLAN heredoc of the WiFi late-command.
func renderUserData(_ environment: Components.Schemas.Environment, server: String, machineURL: String) -> String {
    let packages = environment.packages ?? []
    let values = [
        "SSH_PUBLIC_KEY": yamlQuoted(environment.sshPublicKey),
        "PASSWORD_HASH": yamlQuoted(environment.passwordHash),
        "PXE_SERVER": server,
        "USERNAME": environment.username,
        "TIMEZONE": environment.timezone,
        "WIFI_SSID": heredocEscaped(yamlQuoted(environment.wifi?.ssid ?? "")),
        "WIFI_PASSWORD": heredocEscaped(yamlQuoted(environment.wifi?.password ?? "")),
        "PROVISION_MODE": environment.provisionMode.rawValue,
        "TAILSCALE_AUTH_KEY": "",
        "ROBOT_NET_ADDRESS": environment.robotNetAddress ?? "192.168.20.1/24",
        "ROBOT_NET_PORT": environment.robotNetPort ?? "",
        "PACKAGES": packages.isEmpty ? "    []" : packages.map { "    - \($0)" }.joined(separator: "\n"),
        "MACHINE_URL": machineURL,
        "JOINS_TAILSCALE": (environment.tailscaleAuthKey ?? "").isEmpty ? "" : "true",
    ]
    return envsubst(userDataTemplate, values)
}
