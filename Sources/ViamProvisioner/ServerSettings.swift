import AppKit
import ServiceManagement
import SwiftUI

/// Server mode on this Mac: the hosting toggle, the daemon's state, and Remove Server Data.
struct ServerSettings: View {
    let daemon: ServerDaemon
    @State private var working = false
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Host a provisioning server on this Mac", isOn: Binding(
                get: { daemon.state == .on || daemon.state == .needsApproval },
                set: { on in act { await daemon.setHosting(on) } }))
                .disabled(working || (daemon.unreachablePath != nil && daemon.state == .off))
            if let message = daemon.unreachableMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            status
            if let conflict = daemon.conflict {
                Label(conflict.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let note = daemon.note, note != daemon.unreachableMessage {
                Text(note).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Remove Server Data…", role: .destructive) { confirmingRemove = true }
                    .disabled(working)
                Spacer()
            }
        }
        .padding()
        .task {
            daemon.refresh()
            // launchd restarts a server that crashes, so its registration alone doesn't say it's serving.
            while !Task.isCancelled {
                await daemon.check()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Approval happens in System Settings, so the state can change while the app is in the background.
            daemon.refresh()
            Task { await daemon.check() }
        }
        .confirmationDialog("Remove the server's queue, files and the _viamprovisioner account from this Mac?",
                            isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { act { await daemon.removeServerData() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var status: some View {
        switch daemon.state {
        case .on where daemon.cantStart:
            EmptyView()
        case .on:
            switch daemon.serving {
            case .answering:
                Label("Running at boot", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notAnswering:
                Label(daemon.notAnsweringMessage ?? "", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                Label("Checking the server…", systemImage: "clock").foregroundStyle(.secondary)
            }
        case .needsApproval:
            VStack(alignment: .leading, spacing: 6) {
                Label("Turn on Viam Provisioner under Background App Activity.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        case .missing:
            Label("The server daemon is missing from this copy of the app.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .off:
            EmptyView()
        }
    }

    private func act(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}
