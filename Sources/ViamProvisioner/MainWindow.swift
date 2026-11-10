import ProvisionerKit
import SwiftUI

/// The main window: the queue, the batch history and the environments in the
/// sidebar; the selected one in the detail pane.
struct MainWindow: View {
    let session: ViamSession
    let organizations: OrganizationsModel
    let environments: EnvironmentsModel
    let servers: ServerSelection
    let history: BatchHistory
    let fleet: @Sendable (String) -> any ViamFleet

    @SceneStorage("sidebarSelection") private var selectedItem: String?
    @State private var queue: QueueModel?
    @State private var online: OnlineMonitor?
    @State private var provisioning: ProvisionerKit.Environment?
    @State private var renamingID: UUID?
    @State private var deleting: ProvisionerKit.Environment?
    @State private var failure: String?
    @SwiftUI.Environment(\.undoManager) private var undoManager

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { selectedItem.flatMap(SidebarItem.init(storage:)) }, set: { selectedItem = $0?.storage })
    }

    /// The selected environment's ID; setting it selects that environment.
    private var selection: Binding<UUID?> {
        Binding(get: { sidebarSelection.wrappedValue?.environmentID },
                set: { sidebarSelection.wrappedValue = $0.map(SidebarItem.environment) })
    }

    private var selected: ProvisionerKit.Environment? {
        selection.wrappedValue.flatMap { id in environments.environments.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            EnvironmentSidebar(
                environments: environments, queue: queue, selection: sidebarSelection, renamingID: $renamingID,
                create: { create() }, duplicate: duplicate, delete: { deleting = $0 }, failure: $failure)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let error = environments.loadError {
                    Banner(message: error) {
                        Button("Try Again") { environments.load() }
                    }
                } else if case .failed(let error) = organizations.state {
                    Banner(message: error) {
                        Button("Try Again") { Task { await organizations.load() } }
                    }
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if let environment = selected {
                ToolbarItem(placement: .primaryAction) {
                    Button { provisioning = environment } label: { Label("Provision…", systemImage: "play.fill") }
                        .help("Provision a batch of machines from \(environment.name)")
                }
            }
            ToolbarItem(placement: .primaryAction) { ServerPicker(servers: servers, queue: queue) }
            ToolbarItem(placement: .primaryAction) { AccountStatus(session: session) }
        }
        .task {
            // Browsing fails until Local Network access is granted; keep trying.
            while !Task.isCancelled {
                await servers.browse()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: servers.selected) {
            guard let server = servers.selected else {
                queue = nil
                online = nil
                return
            }
            let model = QueueModel(serverName: server.name, source: ProvisionerClient(baseURL: server.baseURL))
            let monitor = OnlineMonitor(serverURL: server.baseURL, history: history, fleet: fleet)
            queue = model
            online = monitor
            async let watching: Void = monitor.run(model)
            await model.run()
            await watching
        }
        .sheet(item: $provisioning) { environment in
            ProvisionSheet(environment: environment, environments: environments, servers: servers, history: history,
                           refreshQueue: { server in
                               if let queue, queue.serverName == server.name { await queue.refresh() }
                           }) {
                sidebarSelection.wrappedValue = .queue
            }
        }
        .focusedSceneValue(\.environmentActions, EnvironmentActions(
            create: { create() },
            duplicate: selected.map { environment in { duplicate(environment) } },
            rename: selected.map { environment in { renamingID = environment.id } },
            delete: selected.map { environment in { deleting = environment } }))
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) { if let environment = deleting { delete(environment) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its WiFi password and keys are removed from this Mac. Machines already queued with it aren't affected.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var title: String {
        switch sidebarSelection.wrappedValue {
        case .queue: queue.map { "Queue on \($0.serverName)" } ?? "Queue"
        case .history: "History"
        case .environment, nil: selected?.name ?? "Viam Provisioner"
        }
    }

    @ViewBuilder private var detail: some View {
        if sidebarSelection.wrappedValue == .queue {
            QueueView(servers: servers, queue: queue, onlineAt: online?.onlineAt ?? [:])
        } else if sidebarSelection.wrappedValue == .history {
            HistoryView(history: history, queue: queue, onlineAt: online?.onlineAt ?? [:])
        } else if let environment = selected {
            EnvironmentEditor(session: session, organizations: organizations, environments: environments, environment: environment)
                .id(environment.id)
        } else if environments.environments.isEmpty && environments.loadError == nil {
            if !isSignedIn {
                VStack(spacing: 0) {
                    SignInView(session: session)
                    Button("Create an environment without Viam") { create(mode: .osOnly) }
                        .buttonStyle(.link)
                }
            } else {
                ContentUnavailableView {
                    Label("No Environments", systemImage: "square.stack.3d.up")
                } description: {
                    Text("An environment holds the organization, WiFi, SSH key and packages for a batch.")
                } actions: {
                    Button("New Environment") { create() }
                }
            }
        } else {
            ContentUnavailableView("Select an Environment", systemImage: "square.stack.3d.up")
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = session.state { true } else { false }
    }

    private func create(mode: ProvisionMode = .full) {
        do {
            let environment = try environments.create(mode: mode)
            selection.wrappedValue = environment.id
            renamingID = environment.id
            let model = environments
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated { try? model.delete(id: environment.id) }
            }
            undoManager?.setActionName("New Environment")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func duplicate(_ environment: ProvisionerKit.Environment) {
        do {
            let copy = try environments.duplicate(id: environment.id)
            selection.wrappedValue = copy.id
            renamingID = copy.id
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Deletes. When it was selected, selects the row that took its place, or the one above.
    private func delete(_ environment: ProvisionerKit.Environment) {
        let list = environments.environments
        let index = list.firstIndex { $0.id == environment.id } ?? 0
        let wasSelected = selection.wrappedValue == environment.id
        do {
            try environments.delete(id: environment.id)
            let remaining = environments.environments
            if wasSelected {
                selection.wrappedValue = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            }
            undoManager?.removeAllActions(withTarget: environments)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A strip across the top of the detail pane.
struct Banner<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}

/// The menu commands' view of the focused window.
struct EnvironmentActions {
    var create: () -> Void
    var duplicate: (() -> Void)?
    var rename: (() -> Void)?
    var delete: (() -> Void)?
}

// Written out instead of with @Entry, whose macro plugin the Command Line Tools
// lack; scripts/bundle-app.sh builds with whichever toolchain is selected.
private struct EnvironmentActionsKey: FocusedValueKey { typealias Value = EnvironmentActions }
private struct SidebarFocusedKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    var environmentActions: EnvironmentActions? {
        get { self[EnvironmentActionsKey.self] }
        set { self[EnvironmentActionsKey.self] = newValue }
    }

    /// Set while the sidebar list has focus, so ⌘⌫ in a text field never deletes an environment.
    var sidebarFocused: Bool? {
        get { self[SidebarFocusedKey.self] }
        set { self[SidebarFocusedKey.self] = newValue }
    }
}

struct EnvironmentCommands: Commands {
    @FocusedValue(\.environmentActions) private var actions
    @FocusedValue(\.sidebarFocused) private var sidebarFocused

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Environment") { actions?.create() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("Duplicate") { actions?.duplicate?() }
                .keyboardShortcut("d")
                .disabled(actions?.duplicate == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename") { actions?.rename?() }
                .disabled(actions?.rename == nil)
            Button("Delete Environment…") { actions?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.delete == nil || sidebarFocused != true)
        }
    }
}
