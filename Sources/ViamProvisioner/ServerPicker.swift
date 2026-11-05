import ProvisionerKit
import SwiftUI

/// The toolbar's provisioning server: which one, whether its queue is live,
/// and the way to choose another.
struct ServerPicker: View {
    let servers: ServerSelection
    let queue: QueueModel?
    @State private var typingAddress = false

    var body: some View {
        Menu {
            if servers.discovered.isEmpty {
                Text(servers.browseError ?? "No servers found on the network")
            }
            ForEach(servers.discovered, id: \.self) { server in
                Toggle(server.name, isOn: Binding(
                    get: { servers.selected?.name == server.name },
                    set: { if $0 { servers.select(server) } }))
            }
            Divider()
            Button("Connect to Address…") { typingAddress = true }
        } label: {
            Label {
                Text(servers.selected?.name ?? "Choose a Server")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(color)
            }
            .labelStyle(.titleAndIcon)
            .help(help)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .sheet(isPresented: $typingAddress) {
            ServerAddressSheet(servers: servers)
        }
    }

    private var color: Color {
        switch queue?.connection {
        case .live?: .green
        case .waiting?: .orange
        case .connecting?, nil: .secondary
        }
    }

    private var help: String {
        guard let selected = servers.selected else { return "No provisioning server chosen." }
        switch queue?.connection {
        case .live?: return "Following the queue at \(selected.baseURL.absoluteString)."
        case .waiting(_, let message)?:
            return "\(message) Reconnecting automatically."
        case .connecting?, nil: return "Connecting to \(selected.baseURL.absoluteString)…"
        }
    }
}

struct ServerAddressSheet: View {
    let servers: ServerSelection
    @State private var host = ""
    @State private var port = 8235
    @State private var problem: String?
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a Provisioning Server").font(.headline)
            Form {
                TextField("Host", text: $host, prompt: Text("192.168.1.20 or bench.local"))
                TextField("Port", value: $port, format: .number.grouping(.never))
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    do {
                        try servers.connect(host: host, port: port)
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

extension EntryStatus {
    var label: String {
        switch self {
        case .queued: "Waiting"
        case .flashed: "Flashed"
        case .assigned: "Booting"
        case .installing: "Installing"
        case .installed: "Installed"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .queued, .flashed: .secondary
        case .assigned, .installing: .blue
        case .installed: .green
        case .failed: .red
        }
    }
}

struct StatusBadge: View {
    let status: EntryStatus

    var body: some View {
        Label {
            Text(status.label)
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(status.color).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
    }
}
