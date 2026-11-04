import AppKit
import ProvisionerKit
import SwiftUI
import UniformTypeIdentifiers

/// Whether the provisioning server renders installs from the request's
/// environment. The Python server renders from `config/site.env`, so the
/// editor notes which settings it ignores. Delete this, `SectionHeader`'s
/// note and `EnvironmentField.ignoredByPythonServer` once the Swift server ships.
enum ServerSupport {
    static let rendersEnvironment = false
}

struct SectionHeader: View {
    let title: String
    var serverIgnores = false
    @State private var explaining = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if serverIgnores && !ServerSupport.rendersEnvironment {
                Button { explaining = true } label: {
                    Label("Server uses site.env", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $explaining) {
                    Text("""
                    The server running now builds installs from config/site.env on the server Mac, so it ignores these \
                    settings. They're saved here and will be used once the new server ships. To change what machines get \
                    today, edit config/site.env on the server or run `just setup-wizard` there.
                    """)
                    .frame(width: 320)
                    .padding()
                }
            }
        }
    }
}

/// A WiFi password or Tailscale key. A stored value shows as fixed bullets and
/// is read from the Keychain only when revealed. Typing replaces it on Return
/// or leaving the field; the clear button deletes it.
struct SecretField: View {
    let title: String
    let isSet: Bool
    let disabled: Bool
    let reveal: () throws -> String?
    let save: (String?) throws -> Void

    @State private var text = ""
    /// What the field held when editing began: the revealed value, or "".
    @State private var original = ""
    @State private var revealed = false
    @State private var unsaved = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                Group {
                    if revealed {
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text, prompt: isSet && text.isEmpty ? Text("••••••••") : nil)
                    }
                }
                .focused($focused)
                .onSubmit(commit)
                .labelsHidden()
                Button {
                    toggleReveal()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Show")
                .disabled(!isSet && text.isEmpty)
                if isSet {
                    Button {
                        store(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                if unsaved {
                    Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .disabled(disabled)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .alert("Couldn't save the \(title) to the Keychain", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func toggleReveal() {
        if revealed {
            commit()
            revealed = false
            text = ""
            original = ""
        } else {
            do {
                if text.isEmpty {
                    text = try reveal() ?? ""
                    original = text
                }
                revealed = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commit() {
        guard text != original else { return }
        store(text.isEmpty ? nil : text)
    }

    private func store(_ value: String?) {
        do {
            try save(value)
            unsaved = false
            original = revealed ? (value ?? "") : ""
            if !revealed { text = "" }
        } catch {
            unsaved = true
            self.error = error.localizedDescription
        }
    }
}

/// Sets or changes the machines' account password. Only its hash is kept, so
/// it's entered twice and can't be shown later.
struct PasswordSheet: View {
    let save: (String) throws -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password for the machines' account").font(.headline)
            Text("The app keeps only a hash, so the password can't be shown later. Keep it somewhere safe.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
            SecureField("Confirm", text: $confirmation)
            if !confirmation.isEmpty && confirmation != password {
                Text("The passwords don't match.").font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save(password)
                        dismiss()
                    } catch {
                        self.error = "Couldn't save the password to the Keychain: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || password != confirmation)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// The SSH key's summary, its full text on request, and a menu to choose one.
struct SSHKeyRow: View {
    let key: String
    let choose: (String) -> Void
    @State private var showingKey = false
    @State private var keys: [SSHKeyDirectory.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("SSH key") {
                Text(summary).foregroundStyle(key.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                Menu("Choose") {
                    ForEach(keys, id: \.file) { entry in
                        Button("\(entry.file.lastPathComponent) · \(Self.describe(entry.key))") { choose(entry.text) }
                    }
                    if !keys.isEmpty { Divider() }
                    Button("Choose File…", action: chooseFile)
                    Button("Paste from Clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            choose(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
                .fixedSize()
            }
            if !key.isEmpty {
                DisclosureGroup("Show Key", isExpanded: $showingKey) {
                    Text(key).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .onAppear { keys = SSHKeyDirectory.keys(in: URL(filePath: NSHomeDirectory()).appending(path: ".ssh")) }
    }

    private var summary: String {
        switch SSHPublicKey.parse(key) {
        case .success(let parsed): Self.describe(parsed)
        case .failure(.empty): "None"
        case .failure: "Not a public key"
        }
    }

    static func describe(_ key: SSHPublicKey) -> String {
        let type = key.type.replacingOccurrences(of: "ssh-", with: "").uppercased()
        return [type, key.comment, String(key.fingerprint.prefix(15)) + "…"].compactMap { $0 }.joined(separator: " · ")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pub") ?? .data]
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory()).appending(path: ".ssh")
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        choose(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The time zone, chosen from a filterable list of the known zones.
struct TimeZoneRow: View {
    let timezone: String
    let choose: (String) -> Void
    @State private var picking = false
    @State private var filter = ""

    var body: some View {
        LabeledContent("Time zone") {
            Text(timezone)
            Button("Change…") { picking = true }
                .popover(isPresented: $picking) {
                    VStack {
                        TextField("Search", text: $filter).textFieldStyle(.roundedBorder)
                        List(matches, id: \.self) { zone in
                            Button(zone) {
                                choose(zone)
                                picking = false
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .frame(width: 300, height: 360)
                }
        }
    }

    private var matches: [String] {
        let zones = TimeZone.knownTimeZoneIdentifiers
        return filter.isEmpty ? zones : zones.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
