import ProvisionerKit
import SwiftUI

struct EnvironmentSidebar: View {
    let environments: EnvironmentsModel
    @Binding var selection: UUID?
    @Binding var renamingID: UUID?
    let create: () -> Void
    let duplicate: (ProvisionerKit.Environment) -> Void
    let delete: (ProvisionerKit.Environment) -> Void
    @Binding var failure: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Environments") {
                ForEach(environments.environments) { environment in
                    EnvironmentRow(
                        environment: environment, problems: environments.problems(for: environment),
                        renaming: Binding(get: { renamingID == environment.id }, set: { if !$0 { renamingID = nil } }),
                        rename: { try environments.rename(id: environment.id, to: $0) })
                        .tag(environment.id)
                }
            }
        }
        .focused($listFocused)
        .focusedSceneValue(\.sidebarFocused, listFocused)
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("New Environment") { create() }
            if let id = ids.first, let environment = environments.environments.first(where: { $0.id == id }) {
                Button("Duplicate") { duplicate(environment) }
                Button("Rename") { renamingID = id }
                Divider()
                Button("Delete…") { delete(environment) }
            }
        } primaryAction: { ids in
            // Double-click or Return on a row renames it.
            renamingID = ids.first
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: create) { Label("New Environment", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }
}

struct EnvironmentRow: View {
    let environment: ProvisionerKit.Environment
    let problems: [EnvironmentProblem]
    @Binding var renaming: Bool
    let rename: (String) throws -> Void

    @State private var draft = ""
    @State private var note: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Name", text: $draft)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { renaming = false }
                        .onAppear {
                            draft = environment.name
                            fieldFocused = true
                        }
                        .onChange(of: fieldFocused) { _, focused in if !focused && renaming { commit() } }
                } else {
                    Text(environment.name)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let problem = problems.first {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(problem.message)
                    .accessibilityLabel(problem.message)
            }
        }
    }

    private var subtitle: String {
        switch environment.provisionMode {
        case .full: "\(environment.orgName ?? "No organization") · \(environment.locationName ?? "No location")"
        case .agent: "Viam agent only"
        case .osOnly: "OS only"
        }
    }

    /// An empty or taken name reverts, with a note saying why.
    private func commit() {
        renaming = false
        guard draft != environment.name else { return }
        do {
            try rename(draft)
            note = nil
        } catch EnvironmentError.invalid(let problems) {
            note = problems.first?.message
            Task {
                try? await Task.sleep(for: .seconds(4))
                note = nil
            }
        } catch {
            note = error.localizedDescription
        }
    }
}
