import ProvisionerKit
import SwiftUI

/// The main window: environments in the sidebar, the selected one's editor in
/// the detail pane. Queue and History join the sidebar with #38.
struct MainWindow: View {
    let organizations: OrganizationsModel
    let environments: EnvironmentsModel

    @SceneStorage("selectedEnvironment") private var selectedID: String?
    @State private var renamingID: UUID?
    @State private var deleting: ProvisionerKit.Environment?
    @State private var failure: String?
    @SwiftUI.Environment(\.undoManager) private var undoManager

    private var selection: Binding<UUID?> {
        Binding(get: { selectedID.flatMap(UUID.init(uuidString:)) }, set: { selectedID = $0?.uuidString })
    }

    private var selected: ProvisionerKit.Environment? {
        selection.wrappedValue.flatMap { id in environments.environments.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            EnvironmentSidebar(
                environments: environments, selection: selection, renamingID: $renamingID,
                create: { create() }, duplicate: duplicate, delete: { deleting = $0 }, failure: $failure)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let error = environments.loadError ?? organizations.loadError {
                    Banner(message: error) {
                        Button("Try Again") {
                            environments.load()
                            Task { await organizations.load() }
                        }
                    }
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(selected?.name ?? "Viam Provisioner")
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

    @ViewBuilder private var detail: some View {
        if let environment = selected {
            EnvironmentEditor(organizations: organizations, environments: environments, environment: environment)
                .id(environment.id)
        } else if environments.environments.isEmpty && environments.loadError == nil {
            if organizations.rows.isEmpty {
                VStack(spacing: 0) {
                    OnboardingView(command: "just pair-app")
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
