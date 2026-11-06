import ProvisionerKit
import SwiftUI

/// The selected environment's settings. Every change saves as it's committed:
/// text fields on Return or leaving the field, pickers at once. Invalid values
/// are saved too; the problems they cause block provisioning, not editing.
struct EnvironmentEditor: View {
    let session: ViamSession
    let organizations: OrganizationsModel
    let environments: EnvironmentsModel
    /// The environment as stored.
    let environment: ProvisionerKit.Environment

    @State private var draft: ProvisionerKit.Environment
    @State private var packagesText: String
    /// Fields whose "required" problems show; others show only once committed.
    @State private var visited: Set<EnvironmentField> = []
    @State private var settingPassword = false
    @State private var failure: String?
    @FocusState private var focused: EnvironmentField?
    @SwiftUI.Environment(\.undoManager) private var undoManager

    init(session: ViamSession, organizations: OrganizationsModel, environments: EnvironmentsModel,
         environment: ProvisionerKit.Environment) {
        self.session = session
        self.organizations = organizations
        self.environments = environments
        self.environment = environment
        _draft = State(initialValue: environment)
        _packagesText = State(initialValue: environment.packages.joined(separator: "\n"))
    }

    private var committedProblems: [EnvironmentProblem] { environments.problems(for: environment) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                orgBanner
                Form {
                    if !committedProblems.isEmpty {
                        HStack {
                            Label(committedProblems.count == 1 ? "1 setting needs attention" : "\(committedProblems.count) settings need attention",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Show") {
                                visited = Set(EnvironmentField.allCases)
                                if let first = committedProblems.first { withAnimation { proxy.scrollTo(first.field, anchor: .center) } }
                            }
                        }
                    }
                    provisioningSection
                    if draft.provisionMode == .full { viamSection }
                    accountSection
                    networkSection
                    softwareSection
                }
                .formStyle(.grouped)
            }
        }
        .onDisappear {
            // Selecting another environment, ⌘N or closing the window ends the
            // editor without a focus change; a deleted environment isn't saved back.
            if environments.environments.contains(where: { $0.id == environment.id }) { commit() }
        }
        .onChange(of: focused) { previous, _ in
            if let previous {
                visited.insert(previous)
                commit()
            }
        }
        .onChange(of: environment) { _, stored in
            // Undo, a rename in the sidebar or a secret change replaced the stored copy.
            if focused == nil {
                draft = stored
                packagesText = stored.packages.joined(separator: "\n")
            } else {
                draft.name = stored.name
                draft.hasPassword = stored.hasPassword
                draft.hasWifiPassword = stored.hasWifiPassword
                draft.hasTailscaleKey = stored.hasTailscaleKey
            }
        }
        .task(id: "\(draft.orgID ?? "")|\(draft.provisionMode.rawValue)|\(environments.orgIsAvailable(draft))") {
            if draft.provisionMode == .full, let orgID = draft.orgID { await environments.loadLocations(org: orgID) }
        }
        .sheet(isPresented: $settingPassword) {
            PasswordSheet { password in
                try environments.setPassword(password, id: environment.id)
                visited.insert(.password)
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: Sections

    private var provisioningSection: some View {
        Section {
            Picker("Mode", selection: binding(\.provisionMode)) {
                Text("Full").tag(ProvisionMode.full)
                Text("Agent").tag(ProvisionMode.agent)
                Text("OS only").tag(ProvisionMode.osOnly)
            }
            .pickerStyle(.segmented)
            .id(EnvironmentField.provisionMode)
            field(.namePrefix) {
                TextField("Name prefix", text: $draft.namePrefix).focused($focused, equals: .namePrefix).onSubmit(commit)
            }
        } footer: {
            let prefix = draft.namePrefix.isEmpty ? "<prefix>" : draft.namePrefix
            Text("Machines are named \(prefix)-1, \(prefix)-2, …" + (draft.provisionMode == .full ? " and created in Viam." : " (hostnames only)."))
                .foregroundStyle(.secondary)
        }
    }

    private var viamSection: some View {
        Section("Viam") {
            field(.org) {
                if organizations.rows.isEmpty && draft.orgID == nil {
                    LabeledContent("Organization") {
                        Text(isSignedIn ? "Your Viam account has no organizations." : "Sign in to Viam to choose one.")
                            .foregroundStyle(.secondary)
                    }
                } else if let only = onlyChoice(organizations.rows, selected: draft.orgID) {
                    LabeledContent("Organization", value: only.name)
                        .onAppear { if draft.orgID == nil { orgBinding.wrappedValue = only.id } }
                } else {
                    Picker("Organization", selection: orgBinding) {
                        if draft.orgID == nil { Text("Choose…").tag(String?.none) }
                        ForEach(organizations.rows) { org in
                            Text(org.name).tag(Optional(org.id))
                        }
                        if let orgID = draft.orgID, !environments.orgIsAvailable(draft) {
                            Text("\(draft.orgName ?? orgID) (\(isKeyLogin ? EnvironmentsModel.notReachable.lowercased() : "unavailable"))")
                                .tag(Optional(orgID))
                        }
                    }
                    .focused($focused, equals: .org)
                }
            }
            field(.location) { locationRow }
        }
    }

    @ViewBuilder private var locationRow: some View {
        let state = draft.orgID.map { environments.locations(org: $0) } ?? .idle
        switch (draft.orgID, state) {
        case (nil, _):
            Picker("Location", selection: .constant(String?.none)) { Text("Choose an organization first").tag(String?.none) }
                .disabled(true)
        case (_, .loading), (_, .idle):
            LabeledContent("Location") {
                if let name = draft.locationName { Text(name) }
                ProgressView().controlSize(.small)
                Text("Loading locations…").foregroundStyle(.secondary)
            }
        case (let orgID?, .loaded(let locations)):
            Group {
                if let only = onlyChoice(locations, selected: draft.locationID) {
                    LabeledContent("Location", value: only.name)
                } else {
                    Picker("Location", selection: locationBinding(locations)) {
                        if draft.locationID == nil { Text("Choose…").tag(String?.none) }
                        if let locationID = draft.locationID, !locations.contains(where: { $0.id == locationID }) {
                            Text("\(draft.locationName ?? locationID) (\(isKeyLogin ? EnvironmentsModel.notReachable.lowercased() : "missing"))")
                                .tag(Optional(locationID))
                        }
                        ForEach(locations) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .onAppear {
                if draft.locationID == nil, locations.count == 1 {
                    // Select automatically when the org has exactly one location.
                    draft.locationID = locations[0].id
                    draft.locationName = locations[0].name
                    commit()
                } else if let location = locations.first(where: { $0.id == draft.locationID }), draft.locationName != location.name {
                    // An import stores the ID only; keep the name for the sidebar and offline use.
                    draft.locationName = location.name
                    commit()
                }
            }
            .id(orgID)
        case (let orgID?, .rejected(let message)), (let orgID?, .unreachable(let message)):
            LabeledContent("Location") {
                Text(draft.locationName.map { "\($0) (saved)" } ?? "None").foregroundStyle(.secondary)
                Button("Try Again") { Task { await environments.reloadLocations(org: orgID) } }
            }
            .help(message)
        case (_, .unavailable):
            LabeledContent("Location") {
                Text(draft.locationName.map { "\($0) (saved)" } ?? "None").foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section {
            field(.username) {
                TextField("Username", text: $draft.username).focused($focused, equals: .username).onSubmit(commit)
            }
            field(.password) {
                LabeledContent("Password") {
                    if draft.hasPassword {
                        Text("Password set").foregroundStyle(.secondary)
                        Button("Change…") { settingPassword = true }
                    } else {
                        Button("Set Password…") { settingPassword = true }
                    }
                }
            }
            field(.sshPublicKey) {
                SSHKeyRow(key: draft.sshPublicKey) { text in
                    draft.sshPublicKey = text
                    visited.insert(.sshPublicKey)
                    commit()
                }
            }
        } header: {
            SectionHeader(title: "OS Account", serverIgnores: true)
        }
    }

    private var networkSection: some View {
        Section {
            field(.timezone) {
                TimeZoneRow(timezone: draft.timezone) { zone in
                    draft.timezone = zone
                    commit()
                }
            }
            field(.wifiSSID) {
                TextField("WiFi network", text: optional(\.wifiSSID), prompt: Text("None"))
                    .focused($focused, equals: .wifiSSID)
                    .onSubmit(commit)
            }
            field(.wifiPassword) {
                SecretField(title: "WiFi password", isSet: draft.hasWifiPassword,
                            disabled: (draft.wifiSSID ?? "").isEmpty && !draft.hasWifiPassword,
                            reveal: { try environments.revealSecret(.wifiPassword, id: environment.id) },
                            save: { try environments.setSecret(.wifiPassword, $0, id: environment.id) })
            }
            if !(draft.wifiSSID ?? "").isEmpty && !draft.hasWifiPassword {
                Text("No password: machines join it as an open network.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Country", selection: binding(\.wifiCountry)) {
                if let code = draft.wifiCountry, !Self.regions.contains(where: { $0.code == code }) {
                    Text(code).tag(Optional(code))
                }
                ForEach(Self.regions, id: \.code) { region in
                    Text("\(region.name) (\(region.code))").tag(Optional(region.code))
                }
            }
            .disabled((draft.wifiSSID ?? "").isEmpty)
            .id(EnvironmentField.wifiCountry)
        } header: {
            SectionHeader(title: "Network", serverIgnores: true)
        }
    }

    private var softwareSection: some View {
        Section {
            field(.packages) {
                VStack(alignment: .leading) {
                    Text("Packages")
                    TextEditor(text: $packagesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .focused($focused, equals: .packages)
                }
            }
            field(.tailscaleAuthKey) {
                SecretField(title: "Tailscale key", isSet: draft.hasTailscaleKey, disabled: false,
                            reveal: { try environments.revealSecret(.tailscaleAuthKey, id: environment.id) },
                            save: { try environments.setSecret(.tailscaleAuthKey, $0, id: environment.id) })
            }
        } header: {
            SectionHeader(title: "Software", serverIgnores: true)
        } footer: {
            Text("One apt package per line.").foregroundStyle(.secondary)
        }
    }

    // MARK: Org banner

    @ViewBuilder private var orgBanner: some View {
        if environment.provisionMode == .full, let orgID = environment.orgID {
            let orgName = environment.orgName ?? orgID
            if !isSignedIn {
                Banner(message: "Sign in to Viam to use \(orgName).") {
                    SignInButton(session: session)
                }
            } else if organizations.state == .loaded, !environments.orgIsAvailable(environment) {
                Banner(message: isKeyLogin ? "\(orgName) is \(EnvironmentsModel.notReachable.lowercased())." : "Your Viam account can't see \(orgName).") {
                    Button("Choose Another Organization") {
                        visited.insert(.org)
                        focused = .org
                    }
                }
            }
        }
    }

    // MARK: Fields and saving

    /// A row with its problems underneath. A field's "required" problem shows
    /// once it has been visited; any other shows once committed, and clears as
    /// soon as the draft fixes it.
    private func field<Content: View>(_ field: EnvironmentField, @ViewBuilder content: () -> Content) -> some View {
        let draftProblems = draftValue().problems(otherNames: [])
        let shown = committedProblems.filter { problem in
            problem.field == field
                && (draftProblems.contains(problem) || !problem.field.isDraftChecked)
                && (visited.contains(field) || !isEmpty(field))
        }
        return VStack(alignment: .leading, spacing: 4) {
            content()
            ForEach(shown, id: \.message) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHint(problem.message)
            }
        }
        .id(field)
    }

    /// The draft with the packages editor's text applied.
    private func draftValue() -> ProvisionerKit.Environment {
        var value = draft
        value.packages = packagesText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return value
    }

    private func isEmpty(_ field: EnvironmentField) -> Bool {
        switch field {
        case .org: environment.orgID == nil
        case .location: environment.locationID == nil
        case .namePrefix: environment.namePrefix.isEmpty
        case .password: !environment.hasPassword
        case .sshPublicKey: environment.sshPublicKey.isEmpty
        default: false
        }
    }

    /// Saves the draft when it differs from what's stored, as one undoable step.
    private func commit() {
        let value = draftValue()
        guard value != environment else { return }
        let previous = environment
        do {
            try environments.update(value)
            if value.packages != draft.packages { draft.packages = value.packages }
            Self.registerUndo(undoManager, model: environments, restoring: previous, name: "Edit \(previous.name)")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Undo puts `target` back, keeping the current name (a rename is its own
    /// change), and registers the reverse, which UndoManager files as redo.
    private static func registerUndo(_ undoManager: UndoManager?, model: EnvironmentsModel,
                                     restoring target: ProvisionerKit.Environment, name: String) {
        undoManager?.registerUndo(withTarget: model) { model in
            MainActor.assumeIsolated {
                guard let current = model.environments.first(where: { $0.id == target.id }) else { return }
                var restored = target
                restored.name = current.name
                try? model.update(restored)
                registerUndo(undoManager, model: model, restoring: current, name: name)
            }
        }
        undoManager?.setActionName(name)
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<ProvisionerKit.Environment, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: { value in
            draft[keyPath: keyPath] = value
            commit()
        })
    }

    private func optional(_ keyPath: WritableKeyPath<ProvisionerKit.Environment, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }


    /// Changing the org clears the location, whose IDs belong to an org.
    private var orgBinding: Binding<String?> {
        Binding(get: { draft.orgID }, set: { orgID in
            visited.insert(.org)
            guard orgID != draft.orgID else { return }
            draft.orgID = orgID
            draft.orgName = organizations.rows.first { $0.id == orgID }?.name
            draft.locationID = nil
            draft.locationName = nil
            commit()
        })
    }

    private func locationBinding(_ locations: [ViamLocation]) -> Binding<String?> {
        Binding(get: { draft.locationID }, set: { locationID in
            visited.insert(.location)
            draft.locationID = locationID
            draft.locationName = locations.first { $0.id == locationID }?.name
            commit()
        })
    }

    private static let regions: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .map { (code: $0, name: Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    private var isKeyLogin: Bool {
        if case .signedIn(.apiKey) = session.state { true } else { false }
    }

    /// The one choice there is, shown as a label in place of a picker, unless a
    /// stored value outside it is selected.
    private func onlyChoice<Choice: Identifiable>(_ choices: [Choice], selected: Choice.ID?) -> Choice? {
        guard choices.count == 1, selected == nil || selected == choices[0].id else { return nil }
        return choices[0]
    }

    private var isSignedIn: Bool {
        if case .signedIn = session.state { true } else { false }
    }
}

private extension EnvironmentField {
    /// Whether the field's problems can be checked against the draft as it's
    /// typed. Org and secret problems depend on state the draft doesn't hold.
    var isDraftChecked: Bool {
        switch self {
        case .org, .location, .wifiPassword, .password: false
        default: true
        }
    }
}
