import ProvisionerKit
import SwiftUI

/// The batches provisioned from this Mac, each with its machines' progress on
/// the connected server.
struct HistoryView: View {
    let history: BatchHistory
    let queue: QueueModel?
    let onlineAt: [String: Date]
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let error = history.loadError {
                Banner(message: error) {
                    Button("Try Again") { history.load() }
                }
            }
            if history.records.isEmpty {
                ContentUnavailableView("No Batches", systemImage: "clock",
                                       description: Text("Batches provisioned from this Mac appear here."))
            } else {
                HSplitView {
                    List(history.records, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.environmentName)
                            Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.machines.count) queued")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    Group {
                        if let record = history.records.first(where: { $0.id == selection }) {
                            BatchDetail(record: record, queue: queue?.serverName == record.serverName ? queue : nil, onlineAt: onlineAt)
                        } else {
                            ContentUnavailableView("Select a Batch", systemImage: "clock")
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selection == nil { selection = history.records.first?.id }
        }
    }
}

struct BatchDetail: View {
    let record: BatchRecord
    /// The queue of the server the batch went to, when that's the connected one.
    let queue: QueueModel?
    let onlineAt: [String: Date]

    var body: some View {
        Form {
            Section {
                LabeledContent("Provisioned", value: record.date.formatted(date: .long, time: .shortened))
                LabeledContent("Environment", value: record.environmentName)
                if let org = record.orgName {
                    LabeledContent("Viam", value: "\(org) · \(record.locationName ?? "")")
                }
                LabeledContent("Server", value: "\(record.serverName) (\(record.serverURL.absoluteString))")
            }
            Section("Machines") {
                if record.machines.isEmpty {
                    Text("None were queued.").foregroundStyle(.secondary)
                }
                ForEach(record.machines, id: \.self) { name in
                    LabeledContent(name) { status(name) }
                }
            }
            if !record.problems.isEmpty {
                Section("Not queued") {
                    ForEach(record.problems, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func status(_ name: String) -> some View {
        if let queue {
            if let entry = queue.entry(named: name) {
                ProgressBadge(line: ProgressLine(entry: entry, progress: ProvisioningProgress(entry: entry, onlineAt: onlineAt[name])))
            } else if queue.connection == .live {
                Text("No longer queued").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } else {
            Text("Connect to \(record.serverName) to see").foregroundStyle(.secondary)
        }
    }
}
