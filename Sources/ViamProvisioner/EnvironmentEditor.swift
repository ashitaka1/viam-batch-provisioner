import ProvisionerKit
import SwiftUI

/// The selected environment's settings. Every change saves as it's committed:
/// text fields on Return or leaving the field, pickers at once. Invalid values
/// are saved too; the problems they cause block provisioning, not editing.
struct EnvironmentEditor: View {
    let keys: ViamKeys
    let environments: EnvironmentsModel
    /// The environment as stored.
    let environment: ProvisionerKit.Environment

    @State private var draft: EnvironmentDraft
    /// Identifies this editor's unsaved edit to `environments`.
    @State private var editorID = UUID()
    /// Fields whose "required" problems show; others show only once committed.
    @State private var visited: Set<EnvironmentField> = []
    @State private var settingPassword = false
    @State private var addingKey = false
    @State private var failure: String?
    @FocusState private var focused: EnvironmentField?
    @SwiftUI.Environment(\.undoManager) private var undoManager

    init(keys: ViamKeys, environments: EnvironmentsModel, environment: ProvisionerKit.Environment) {
        self.keys = keys
        self.environments = environments
        self.environment = environment
        _draft = State(initialValue: EnvironmentDraft(environment))
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
                    if draft.environment.provisionMode == .full { viamSection }
                    accountSection
                    networkSection
                    robotNetworkSection
                    softwareSection
                }
                .formStyle(.grouped)
            }
        }
        .onDisappear {
            // Selecting another environment, ⌘N or closing the window ends the
            // editor without a focus change.
            commit()
            environments.setPendingEdit(for: editorID, environment: environment.id, nil)
        }
        .onAppear {
            // Provision and Duplicate save an edit still in a field.
            environments.setPendingEdit(for: editorID, environment: environment.id) { commit() }
        }
        .onChange(of: focused) { previous, _ in
            if let previous {
                visited.insert(previous)
                commit()
            }
        }
        .onChange(of: environment) { old, stored in
            draft.storedChanged(from: old, to: stored)
        }
        // The keys are part of the ID: a key added or removed forgets the loaded locations.
        .task(id: "\(draft.environment.orgID ?? "")|\(draft.environment.provisionMode.rawValue)|\(keys.keys.map(\.keyID))") {
            if draft.environment.provisionMode == .full, let orgID = draft.environment.orgID { await environments.loadLocations(org: orgID) }
        }
        .sheet(isPresented: $addingKey) { AddKeyForm(keys: keys) }
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
                TextField("Name prefix", text: $draft.environment.namePrefix).focused($focused, equals: .namePrefix).onSubmit(commit)
            }
        } footer: {
            let prefix = draft.environment.namePrefix.isEmpty ? "<prefix>" : draft.environment.namePrefix
            Text("Machines are named \(prefix)-1, \(prefix)-2, …" + (draft.environment.provisionMode == .full ? " and created in Viam." : " (hostnames only)."))
                .foregroundStyle(.secondary)
        }
    }

    private var viamSection: some View {
        Section("Viam") {
            field(.org) {
                if organizationRows.isEmpty && draft.environment.orgID == nil {
                    LabeledContent("Organization") {
                        Text("Add a Viam API key to choose one.").foregroundStyle(.secondary)
                    }
                } else if let only = onlyChoice(organizationRows, selected: draft.environment.orgID) {
                    LabeledContent("Organization", value: only.name)
                        .onAppear { if draft.environment.orgID == nil { orgBinding.wrappedValue = only.id } }
                } else {
                    Picker("Organization", selection: orgBinding) {
                        if draft.environment.orgID == nil { Text("Choose…").tag(String?.none) }
                        ForEach(organizationRows) { org in
                            Text(org.name).tag(Optional(org.id))
                        }
                        if let orgID = draft.environment.orgID, !environments.orgIsAvailable(draft.environment) {
                            Text("\(draft.environment.orgName ?? orgID) (\(EnvironmentsModel.notReachable.lowercased()))")
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
        let state = draft.environment.orgID.map { environments.locations(org: $0) } ?? .idle
        switch (draft.environment.orgID, state) {
        case (nil, _):
            Picker("Location", selection: .constant(String?.none)) { Text("Choose an organization first").tag(String?.none) }
                .disabled(true)
        case (_, .loading), (_, .idle):
            LabeledContent("Location") {
                if let name = draft.environment.locationName { Text(name) }
                ProgressView().controlSize(.small)
                Text("Loading locations…").foregroundStyle(.secondary)
            }
        case (let orgID?, .loaded(let locations)):
            Group {
                if let only = onlyChoice(locations, selected: draft.environment.locationID) {
                    LabeledContent("Location", value: only.name)
                } else {
                    Picker("Location", selection: locationBinding(locations)) {
                        if draft.environment.locationID == nil { Text("Choose…").tag(String?.none) }
                        if let locationID = draft.environment.locationID, !locations.contains(where: { $0.id == locationID }) {
                            Text("\(draft.environment.locationName ?? locationID) (\(environments.isUnreachableWithKey(draft.environment) ? EnvironmentsModel.notReachable.lowercased() : "missing"))")
                                .tag(Optional(locationID))
                        }
                        ForEach(locations) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .onAppear {
                if draft.environment.locationID == nil, locations.count == 1 {
                    // Select automatically when the org has exactly one location.
                    draft.environment.locationID = locations[0].id
                    draft.environment.locationName = locations[0].name
                    commit()
                } else if let location = locations.first(where: { $0.id == draft.environment.locationID }), draft.environment.locationName != location.name {
                    // An import stores the ID only; keep the name for the sidebar and offline use.
                    draft.environment.locationName = location.name
                    commit()
                }
            }
            .id(orgID)
        case (let orgID?, .rejected(let message)), (let orgID?, .unreachable(let message)):
            LabeledContent("Location") {
                Text(draft.environment.locationName.map { "\($0) (saved)" } ?? "None").foregroundStyle(.secondary)
                Button("Try Again") { Task { await environments.reloadLocations(org: orgID) } }
            }
            .help(message)
        case (_, .unavailable):
            LabeledContent("Location") {
                Text(draft.environment.locationName.map { "\($0) (saved)" } ?? "None").foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section {
            field(.username) {
                TextField("Username", text: $draft.environment.username).focused($focused, equals: .username).onSubmit(commit)
            }
            field(.password) {
                LabeledContent("Password") {
                    if draft.environment.hasPassword {
                        Text("Password set").foregroundStyle(.secondary)
                        Button("Change…") { settingPassword = true }
                            .accessibilityLabel("Change Password")
                    } else {
                        Button("Set Password…") { settingPassword = true }
                            .accessibilityLabel("Set Password")
                    }
                }
            }
            field(.sshPublicKey) {
                SSHKeyRow(key: draft.environment.sshPublicKey) { text in
                    draft.environment.sshPublicKey = text
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
                TimeZoneRow(timezone: draft.environment.timezone) { zone in
                    draft.environment.timezone = zone
                    commit()
                }
            }
            field(.wifiSSID) {
                TextField("WiFi network", text: optional(\.wifiSSID), prompt: Text("None"))
                    .focused($focused, equals: .wifiSSID)
                    .onSubmit(commit)
            }
            field(.wifiPassword) {
                SecretField(title: "WiFi password", isSet: draft.environment.hasWifiPassword,
                            disabled: (draft.environment.wifiSSID ?? "").isEmpty && !draft.environment.hasWifiPassword,
                            reveal: { try environments.revealSecret(.wifiPassword, id: environment.id) },
                            save: { try environments.setSecret(.wifiPassword, $0, id: environment.id) })
            }
            if !(draft.environment.wifiSSID ?? "").isEmpty && !draft.environment.hasWifiPassword {
                Text("No password: machines join it as an open network.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Country", selection: binding(\.wifiCountry)) {
                if let code = draft.environment.wifiCountry, !Self.regions.contains(where: { $0.code == code }) {
                    Text(code).tag(Optional(code))
                }
                ForEach(Self.regions, id: \.code) { region in
                    Text("\(region.name) (\(region.code))").tag(Optional(region.code))
                }
            }
            .disabled((draft.environment.wifiSSID ?? "").isEmpty)
            .id(EnvironmentField.wifiCountry)
        } header: {
            SectionHeader(title: "Network", serverIgnores: true)
        }
    }

    private var robotNetworkSection: some View {
        Section {
            Toggle("Robot network", isOn: binding(\.robotNetEnabled))
            field(.robotNetAddress) {
                TextField("Address", text: $draft.environment.robotNetAddress, prompt: Text(RobotNetwork.defaultAddress))
                    .focused($focused, equals: .robotNetAddress)
                    .onSubmit(commit)
            }
            .disabled(!draft.environment.robotNetEnabled)
            field(.robotNetPort) {
                TextField("Port", text: optional(\.robotNetPort), prompt: Text("Any other enp* port"))
                    .focused($focused, equals: .robotNetPort)
                    .onSubmit(commit)
            }
            .disabled(!draft.environment.robotNetEnabled)
        } header: {
            SectionHeader(title: "Robot Network", serverIgnores: true)
        } footer: {
            Text(draft.environment.robotNetEnabled
                 ? "The port gets this static address, and every other wired port DHCP. With no port, the first enp* port other than the one cabled at install gets it."
                 : "Machines get no robot network.")
                .foregroundStyle(.secondary)
        }
    }

    private var softwareSection: some View {
        Section {
            field(.packages) {
                VStack(alignment: .leading) {
                    Text("Packages")
                    TextEditor(text: $draft.packagesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .focused($focused, equals: .packages)
                }
            }
            field(.tailscaleAuthKey) {
                SecretField(title: "Tailscale key", isSet: draft.environment.hasTailscaleKey, disabled: false,
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
            if keys.loaded && !keys.isSignedIn {
                Banner(message: "Add a Viam API key to use \(orgName).") {
                    AddKeyButton(adding: $addingKey)
                }
            } else if keys.loaded, !environments.orgIsAvailable(environment) {
                Banner(message: "\(orgName) is \(EnvironmentsModel.notReachable.lowercased()).") {
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
        let draftProblems = draft.value.problems(otherNames: [])
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
    /// Reads the stored copy from `environments`: a pending edit runs from a copy
    /// of this view, and a deleted environment isn't saved back.
    private func commit() {
        let value = draft.value
        guard let previous = environments.environments.first(where: { $0.id == environment.id }),
              value != previous else { return }
        do {
            try environments.update(value)
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
        Binding(get: { draft.environment[keyPath: keyPath] }, set: { value in
            draft.environment[keyPath: keyPath] = value
            commit()
        })
    }

    private func optional(_ keyPath: WritableKeyPath<ProvisionerKit.Environment, String?>) -> Binding<String> {
        Binding(get: { draft.environment[keyPath: keyPath] ?? "" }, set: { draft.environment[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }


    /// Changing the org clears the location, whose IDs belong to an org.
    private var orgBinding: Binding<String?> {
        Binding(get: { draft.environment.orgID }, set: { orgID in
            visited.insert(.org)
            guard orgID != draft.environment.orgID else { return }
            draft.environment.orgID = orgID
            draft.environment.orgName = organizationRows.first { $0.id == orgID }?.name
            draft.environment.locationID = nil
            draft.environment.locationName = nil
            commit()
        })
    }

    private func locationBinding(_ locations: [ViamLocation]) -> Binding<String?> {
        Binding(get: { draft.environment.locationID }, set: { locationID in
            visited.insert(.location)
            draft.environment.locationID = locationID
            draft.environment.locationName = locations.first { $0.id == locationID }?.name
            commit()
        })
    }

    private static let regions: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .map { (code: $0, name: Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    private var organizationRows: [ViamOrganization] {
        if case .known(let orgs) = keys.orgs { orgs } else { [] }
    }

    /// The one choice there is, shown as a label in place of a picker, unless a
    /// stored value outside it is selected.
    private func onlyChoice<Choice: Identifiable>(_ choices: [Choice], selected: Choice.ID?) -> Choice? {
        guard choices.count == 1, selected == nil || selected == choices[0].id else { return nil }
        return choices[0]
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
