import ProvisionerKit
import SwiftUI

/// The connected server's queue, live from its event stream, with the
/// selected machine's detail in the inspector.
struct QueueView: View {
    let servers: ServerSelection
    let queue: QueueModel?
    let onlineAt: [String: Date]

    @State private var selection: String?
    @State private var showingDetail = false
    @State private var removing: String?
    @State private var failure: String?

    var body: some View {
        if let queue {
            content(queue)
        } else {
            ContentUnavailableView {
                Label("No Server", systemImage: "server.rack")
            } description: {
                Text("Choose a provisioning server from the toolbar to see its queue.")
            }
        }
    }

    private func content(_ queue: QueueModel) -> some View {
        VStack(spacing: 0) {
            if case .waiting(_, let message) = queue.connection {
                Banner(message: "\(queue.serverName): \(message) Reconnecting automatically.") {}
            }
            CountsBar(counts: queue.counts, total: queue.entries.count)
            Divider()
            if queue.entries.isEmpty {
                ContentUnavailableView(
                    queue.connection == .live ? "The Queue Is Empty" : "Connecting…", systemImage: "tray",
                    description: Text(queue.connection == .live ? "Provision a batch from an environment." : queue.serverName))
            } else {
                QueueTable(entries: queue.entries, onlineAt: onlineAt, selection: $selection, remove: { removing = $0 })
            }
        }
        .onChange(of: selection) { _, name in if name != nil { showingDetail = true } }
        .inspector(isPresented: $showingDetail) {
            Group {
                if let name = selection, let entry = queue.entry(named: name) {
                    MachineDetail(entry: entry, progress: ProvisioningProgress(entry: entry, onlineAt: onlineAt[name]),
                                  timeline: queue.timeline(for: name))
                } else {
                    ContentUnavailableView("No Machine Selected", systemImage: "desktopcomputer")
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 340)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await queue.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Read the whole queue from the server again")
            }
            ToolbarItem {
                Button { showingDetail.toggle() } label: { Label("Machine Detail", systemImage: "sidebar.right") }
            }
        }
        .confirmationDialog("Remove \"\(removing ?? "")\" from the queue?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let name = removing else { return }
                Task {
                    do {
                        try await queue.remove(named: name)
                    } catch {
                        failure = (error as? ProvisionerError)?.sendMessage ?? error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its staged credentials are deleted from the server. A machine created in Viam stays there.")
        }
        .alert("Couldn't remove the machine", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }
}

struct CountsBar: View {
    let counts: QueueModel.Counts
    let total: Int

    var body: some View {
        HStack(spacing: 16) {
            count(counts.waiting, "Queued", .secondary)
            count(counts.installing, "In progress", .blue)
            count(counts.installed, "Installed", .green)
            count(counts.failed, "Failed", .red)
            Spacer()
            Text(total == 1 ? "1 machine" : "\(total) machines").foregroundStyle(.secondary).fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").foregroundStyle(color).imageScale(.small)
            Text("\(value) \(label.lowercased())").monospacedDigit()
        }
        .fixedSize()
    }
}

struct QueueTable: View {
    let entries: [QueueEntry]
    let onlineAt: [String: Date]
    @Binding var selection: String?
    let remove: (String) -> Void

    var body: some View {
        Table(entries.map { Row(entry: $0, progress: ProvisioningProgress(entry: $0, onlineAt: onlineAt[$0.name])) },
              selection: $selection) {
            TableColumn("Name", value: \.entry.name)
            TableColumn("Progress") { ProgressBadge(line: $0.line) }
                .width(min: 140, ideal: 300)
            TableColumn("MAC") { Text($0.entry.mac ?? ($0.entry.flashedViaUSB ? "USB" : "")).monospaced() }
            TableColumn("Updated") { row in
                if let date = row.entry.lastChange { Text(date, format: .dateTime.month().day().hour().minute()) }
            }
            TableColumn("Failure") { Text($0.entry.failureReason ?? "").foregroundStyle(.red).help($0.entry.failureReason ?? "") }
        }
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first {
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(name, forType: .string)
                }
                Divider()
                Button("Remove from Queue…") { remove(name) }
            }
        }
    }
}

extension QueueTable {
    struct Row: Identifiable {
        let entry: QueueEntry
        let progress: ProvisioningProgress?

        var id: String { entry.name }
        var line: ProgressLine { ProgressLine(entry: entry, progress: progress) }
    }
}

struct MachineDetail: View {
    let entry: QueueEntry
    let progress: ProvisioningProgress?
    let timeline: [MachineEvent]

    var body: some View {
        Form {
            Section {
                LabeledContent("Progress") { ProgressBadge(line: ProgressLine(entry: entry, progress: progress)) }
                LabeledContent("Hostname", value: entry.name)
                LabeledContent("MAC", value: entry.mac ?? (entry.flashedViaUSB ? "Flashed to USB" : "Not yet booted"))
                if progress == nil, let stage = entry.stage { LabeledContent("Install stage", value: stage) }
                LabeledContent("Viam credentials", value: entry.hasCredentials ? "Staged" : "None")
            }
            if let progress {
                Section("Steps") {
                    ForEach(Array(progress.rows.enumerated()), id: \.offset) { _, row in
                        StepLine(title: row.title, state: row.state, at: row.at)
                        ForEach(row.subSteps, id: \.title) { sub in
                            StepLine(title: sub.title, state: sub.state, at: nil).padding(.leading, 20)
                        }
                    }
                }
                if !progress.earlierAttempts.isEmpty {
                    Section("Earlier attempts") {
                        ForEach(Array(progress.earlierAttempts.enumerated()), id: \.offset) { index, rows in
                            DisclosureGroup("Attempt \(index + 1)") {
                                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                    LabeledContent(row.title) {
                                        if let at = row.at { Text(at, format: .dateTime.hour().minute().second()).monospacedDigit() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section("Times") {
                time("Assigned", entry.assignedAt)
                time("Completed", entry.completedAt)
                time("Failed", entry.failedAt)
            }
            if let reason = entry.failureReason {
                Section("Failure") {
                    Text(reason).textSelection(.enabled)
                }
            }
            Section("Events") {
                if timeline.isEmpty {
                    Text("No events since the app connected.").foregroundStyle(.secondary)
                }
                ForEach(timeline, id: \.id) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary)
                        Text(event.timestamp, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func time(_ label: String, _ date: Date?) -> some View {
        if let date {
            LabeledContent(label) { Text(date, format: .dateTime.month().day().hour().minute().second()) }
        }
    }
}

/// One step or sub-step in the machine detail: its state's symbol, title and time.
struct StepLine: View {
    let title: String
    let state: ProvisioningProgress.State
    let at: Date?

    var body: some View {
        LabeledContent {
            if let at { Text(at, format: .dateTime.hour().minute().second()).monospacedDigit() }
        } label: {
            Label {
                Text(title).foregroundStyle(state == .pending ? .secondary : .primary)
            } icon: {
                symbol
            }
        }
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .current: Image(systemName: "circle.dotted.circle").foregroundStyle(.blue)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

extension QueueEntry {
    /// The newest of its timestamps.
    var lastChange: Date? {
        [assignedAt, completedAt, failedAt].compactMap { $0 }.max()
    }
}

extension MachineEvent {
    var summary: String {
        switch kind {
        case .assigned: "Booted from the network\(mac.map { " as \($0)" } ?? "")"
        case .installStarted: "Installer started"
        case .installProgress(let stage): "Install stage: \(stage)"
        case .installFailed(let stage, let reason, let source):
            "Failed at \(stage) (\(source.rawValue)): \(reason)"
        case .installComplete(let duration): "Installed in \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds])))"
        case .guardInstalled(let reason): "Boot guard set (\(reason.rawValue))"
        case .stepReached(let step, _): "Reached \(step.title())"
        case .downloadProgress(let bytes, let total): "Downloaded \(Int(((ProvisioningProgress.fraction(bytes: bytes, total: total) ?? 0) * 100).rounded()))%"
        }
    }
}
