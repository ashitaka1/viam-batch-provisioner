import ProvisionerKit
import SwiftUI

/// The selected environment's settings. Every change saves as it's committed:
/// text fields on Return or leaving the field, pickers at once. Invalid values
/// are saved too; the problems they cause block provisioning, not editing.
struct EnvironmentEditor: View {
    let organizations: OrganizationsModel
    let environments: EnvironmentsModel
    /// The environment as stored.
    let environment: ProvisionerKit.Environment

    @State private var draft: ProvisionerKit.Environment
    @State private var packagesText: String
    /// Fields whose "required" problems show; others show only once committed.
    @State private var visited: Set<EnvironmentField> = []
    @State private var pairCommand: String?
    @State private var settingPassword = false
    @State private var failure: String?
    @FocusState private var focused: EnvironmentField?
    @SwiftUI.Environment(\.undoManager) private var undoManager

    init(organizations: OrganizationsModel, environments: EnvironmentsModel, environment: ProvisionerKit.Environment) {
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
        .task(id: draft.orgID) {
            if draft.provisionMode == .full, let orgID = draft.orgID { await environments.loadLocations(org: orgID) }
        }
        .sheet(item: Binding(get: { pairCommand.map(PairCommand.init) }, set: { pairCommand = $0?.command })) { item in
            VStack {
                OnboardingView(title: "Add a Viam organization", command: item.command, waiting: false)
                Button("Close") { pairCommand = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(.bottom)
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
                TextField("Name prefix", text: $draft.namePrefix).focused($focused, equals: .namePrefix)
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
                        Text("No organizations paired.").foregroundStyle(.secondary)
                        Button("Add Organization…") { pairCommand = "just pair-app" }
                    }
                } else {
                    Picker("Organization", selection: orgBinding) {
                        if draft.orgID == nil { Text("Choose…").tag(String?.none) }
                        ForEach(organizations.rows) { row in
                            Text(row.credential.orgName).tag(Optional(row.credential.orgID))
                        }
                        if let orgID = draft.orgID, !environments.orgIsPaired(draft) {
                            Text("\(draft.orgName ?? orgID) (not paired)").tag(Optional(orgID))
                        }
                        Divider()
                        Text("Add Organization…").tag(Optional(Self.addOrganizationTag))
                    }
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
            Picker("Location", selection: locationBinding(locations)) {
                if draft.locationID == nil || !locations.contains(where: { $0.id == draft.locationID }) {
                    Text("Choose…").tag(String?.none)
                }
                ForEach(locations) { Text($0.name).tag(Optional($0.id)) }
            }
            .onAppear {
                // Select automatically when the org has exactly one location.
                if draft.locationID == nil, locations.count == 1 {
                    draft.locationID = locations[0].id
                    draft.locationName = locations[0].name
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
        case (_, .unpaired):
            LabeledContent("Location") {
                Text(draft.locationName.map { "\($0) (saved)" } ?? "None").foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section {
            field(.username) {
                TextField("Username", text: $draft.username).focused($focused, equals: .username)
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
            if !environments.orgIsPaired(environment) {
                Banner(message: "\(orgName) isn't paired on this Mac.") {
                    Button("Pair \(orgName)…") { pairCommand = "just pair-app --org-id \(orgID)" }
                    Button("Choose Another Organization") { focused = nil; visited.insert(.org) }
                }
            } else if case .rejected? = organizations.rows.first(where: { $0.credential.orgID == orgID })?.status {
                Banner(message: "Viam rejected the key for \(orgName).") {
                    Button("Re-pair \(orgName)…") { pairCommand = "just pair-app --org-id \(orgID)" }
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
            let model = environments
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated { try? model.update(previous) }
            }
            undoManager?.setActionName("Edit \(previous.name)")
        } catch {
            failure = error.localizedDescription
        }
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

    private static let addOrganizationTag = "\u{0}add-organization"

    /// Changing the org clears the location, whose IDs belong to an org.
    private var orgBinding: Binding<String?> {
        Binding(get: { draft.orgID }, set: { orgID in
            visited.insert(.org)
            if orgID == Self.addOrganizationTag {
                pairCommand = "just pair-app"
                return
            }
            guard orgID != draft.orgID else { return }
            draft.orgID = orgID
            draft.orgName = organizations.rows.first { $0.credential.orgID == orgID }?.credential.orgName
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

    private struct PairCommand: Identifiable {
        let command: String
        var id: String { command }
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
