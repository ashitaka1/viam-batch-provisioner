import ProvisionerKit
import SwiftUI

/// What the sidebar selects.
enum SidebarItem: Hashable {
    case queue
    case history
    case environment(UUID)

    init?(storage: String) {
        switch storage {
        case "queue": self = .queue
        case "history": self = .history
        default:
            guard let id = UUID(uuidString: storage) else { return nil }
            self = .environment(id)
        }
    }

    var storage: String {
        switch self {
        case .queue: "queue"
        case .history: "history"
        case .environment(let id): id.uuidString
        }
    }

    var environmentID: UUID? {
        if case .environment(let id) = self { id } else { nil }
    }
}

struct EnvironmentSidebar: View {
    let environments: EnvironmentsModel
    let queue: QueueModel?
    @Binding var selection: SidebarItem?
    @Binding var renamingID: UUID?
    let create: () -> Void
    let duplicate: (ProvisionerKit.Environment) -> Void
    let delete: (ProvisionerKit.Environment) -> Void
    @Binding var failure: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Provisioning") {
                Label("Queue", systemImage: "list.bullet.rectangle")
                    .badge(queue.map { $0.counts.installing + $0.counts.waiting } ?? 0)
                    .tag(SidebarItem.queue)
                Label("History", systemImage: "clock")
                    .tag(SidebarItem.history)
            }
            Section("Environments") {
                ForEach(environments.environments) { environment in
                    EnvironmentRow(
                        environment: environment, problems: environments.problems(for: environment),
                        unreachable: environments.isUnreachableWithKey(environment),
                        selected: selection == .environment(environment.id),
                        renaming: Binding(get: { renamingID == environment.id }, set: { if !$0 { renamingID = nil } }),
                        rename: { try environments.rename(id: environment.id, to: $0) })
                        .tag(SidebarItem.environment(environment.id))
                }
            }
        }
        .focused($listFocused)
        .focusedSceneValue(\.sidebarFocused, listFocused)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            Button("New Environment") { create() }
            if let id = items.first?.environmentID, let environment = environments.environments.first(where: { $0.id == id }) {
                Button("Duplicate") { duplicate(environment) }
                Button("Rename") { renamingID = id }
                Divider()
                Button("Delete…") { delete(environment) }
            }
        } primaryAction: { items in
            // Double-click or Return on an environment renames it.
            renamingID = items.first?.environmentID
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
    /// Out of the signed-in API key's reach.
    var unreachable = false
    var selected = false
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
                if unreachable {
                    Text(EnvironmentsModel.notReachable).font(.caption).foregroundStyle(warningStyle)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            // A sidebar row keeps the height it was first given, so a note in it can't wrap.
            .popover(isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } }), arrowEdge: .trailing) {
                Text(note ?? "").fixedSize(horizontal: false, vertical: true).frame(width: 240).padding()
            }
            Spacer()
            if let problem = problems.first {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(warningStyle)
                    .help(problem.message)
                    .accessibilityLabel(problem.message)
            }
        }
    }

    /// Orange, except on the selected row, where the accent fill leaves it unreadable.
    private var warningStyle: AnyShapeStyle {
        selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange)
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
