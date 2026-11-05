import ProvisionerKit
import SwiftUI

/// Provisions a batch from one environment into the chosen server's queue:
/// the count, then progress, then what was queued and what wasn't.
struct ProvisionSheet: View {
    let environment: ProvisionerKit.Environment
    let environments: EnvironmentsModel
    let servers: ServerSelection
    let history: BatchHistory
    /// Reads the server's queue again, when it's the one the window follows.
    let refreshQueue: @MainActor (DiscoveredServer) async -> Void
    let showQueue: () -> Void

    @State private var count = 1
    @State private var run: ProvisioningRun?
    @State private var server: DiscoveredServer?
    @State private var recordID = UUID()
    @State private var historyError: String?
    @State private var working = false
    /// Read when the sheet opens: finding them reads the environment's secrets.
    @State private var settingsProblems: [EnvironmentProblem] = []
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provision from \(environment.name)").font(.title3.bold())
            if let run {
                progress(run)
            } else {
                setup
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(isBusy)
        .onAppear { settingsProblems = Self.problems(environment, environments) }
    }

    private var isBusy: Bool {
        working || run.map { [.readingQueue, .creatingInViam, .sending].contains($0.phase) } ?? false
    }

    // MARK: Before the run

    @ViewBuilder private var setup: some View {
        let problems = settingsProblems
        Form {
            LabeledContent("Mode", value: modeName)
            if environment.provisionMode == .full {
                LabeledContent("Viam", value: "\(environment.orgName ?? "No organization") · \(environment.locationName ?? "No location")")
            }
            LabeledContent("Server", value: servers.selected?.name ?? "None chosen")
            LabeledContent("Machines") {
                HStack {
                    TextField("Machines", value: $count, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 56)
                    Stepper("Machines", value: $count, in: 1...500).labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        Text(namesNote).font(.callout).foregroundStyle(.secondary)
        if servers.selected == nil {
            Label("Choose a provisioning server from the toolbar first.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Fix the environment first:", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                ForEach(problems, id: \.message) { Text("• \($0.message)").font(.callout) }
            }
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Provision") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || servers.selected == nil || !(1...500).contains(count))
        }
    }

    private var modeName: String {
        switch environment.provisionMode {
        case .full: "Full: OS, Viam agent and machine credentials"
        case .agent: "Agent: OS and Viam agent, no credentials"
        case .osOnly: "OS only"
        }
    }

    private var namesNote: String {
        let prefix = environment.namePrefix.isEmpty ? "<prefix>" : environment.namePrefix
        let where_ = environment.provisionMode == .full ? "the Viam location and the queue" : "the queue"
        return "Machines are named \(prefix)-1, \(prefix)-2, …, skipping names already in \(where_)."
    }

    private static func problems(_ environment: ProvisionerKit.Environment, _ environments: EnvironmentsModel) -> [EnvironmentProblem] {
        do {
            _ = try environments.provisioningSettings(id: environment.id)
            return []
        } catch EnvironmentError.invalid(let problems) {
            return problems
        } catch {
            return [EnvironmentProblem(field: .name, message: error.localizedDescription)]
        }
    }

    private func start() {
        guard let server = servers.selected, let settings = try? environments.provisioningSettings(id: environment.id) else { return }
        let run = ProvisioningRun(
            environment: environment, config: settings.config,
            server: ProvisionerClient(baseURL: server.baseURL), fleet: settings.fleet)
        self.server = server
        self.run = run
        let count = count
        Task {
            await run.start(count: count)
            record(run)
            await refreshQueue(server)
        }
    }

    private func record(_ run: ProvisioningRun) {
        guard run.phase == .finished, let server else { return }
        do {
            try history.save(BatchRecord(id: recordID, environment: environment, outcome: run.outcome, server: server, date: .now))
            historyError = nil
        } catch {
            historyError = "The batch wasn't added to the history: \(error.localizedDescription)"
        }
    }

    // MARK: During and after the run

    @ViewBuilder private func progress(_ run: ProvisioningRun) -> some View {
        switch run.phase {
        case .ready, .readingQueue:
            step("Reading the queue on \(server?.name ?? "the server")…")
        case .creatingInViam:
            step("Creating \(count) machines in \(environment.locationName ?? "Viam")…")
        case .sending:
            step("Adding machines to the queue…")
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing was created or queued.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        case .finished:
            summary(run)
        }
    }

    private func step(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    @ViewBuilder private func summary(_ run: ProvisioningRun) -> some View {
        let outcome = run.outcome
        if !outcome.queued.isEmpty {
            Label(outcome.queued.count == 1 ? "Queued 1 machine" : "Queued \(outcome.queued.count) machines",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(outcome.queued.joined(separator: ", ")).font(.callout).textSelection(.enabled)
            Text("Network-boot each machine; the queue shows each install.").font(.callout).foregroundStyle(.secondary)
        }
        let problems = outcome.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(outcome.queued.isEmpty ? "Nothing was queued" : "Some machines weren't queued",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(problems, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        if let error = outcome.deleteError {
            Text("Viam didn't delete:\n\(error)").font(.callout).foregroundStyle(.red)
        }
        if let historyError {
            Text(historyError).font(.callout).foregroundStyle(.orange)
        }
        HStack {
            if !outcome.unqueued.isEmpty {
                Button("Delete from Viam") { act(run) { await run.deleteUnqueued() } }
            }
            if run.canRetry {
                Button("Retry Sending") { act(run) { await run.retrySending() } }
            }
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Done") { dismiss() }
            Button("Show Queue") {
                showQueue()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(outcome.queued.isEmpty)
        }
        .disabled(working)
    }

    private func act(_ run: ProvisioningRun, _ body: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await body()
            record(run)
            if let server { await refreshQueue(server) }
            working = false
        }
    }
}
