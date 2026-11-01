import ProvisionerKit
import SwiftUI

struct OrganizationsSettings: View {
    let model: OrganizationsModel
    @State private var removing: OrganizationsModel.Row?
    @State private var instructions: String?
    @State private var removeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.rows.isEmpty {
                Text("No organizations yet.").foregroundStyle(.secondary)
            } else {
                List(model.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.credential.orgName).bold()
                            Text("\(row.credential.keyName) (\(row.credential.keyID.prefix(5))…) · \(Self.describe(row.status))")
                                .font(.caption)
                                .foregroundStyle(Self.isRejected(row.status) ? .orange : .secondary)
                        }
                        Spacer()
                        if Self.isRejected(row.status) {
                            Button("Re-pair") { instructions = "just pair-app --org-id \(row.credential.orgID)" }
                        }
                        Button("Remove") { removing = row }
                    }
                }
            }
            HStack {
                Button("Add organization…") { instructions = "just pair-app" }
                Spacer()
                Button("Check again") { Task { await model.recheck() } }
                    .disabled(model.rows.isEmpty)
            }
        }
        .padding()
        .sheet(item: Binding(get: { instructions.map(Instructions.init) }, set: { instructions = $0?.command })) { item in
            VStack {
                OnboardingView(title: "Add a Viam organization", command: item.command, waiting: false)
                Button("Close") { instructions = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(.bottom)
        }
        .alert("Remove \(removing?.credential.orgName ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let row = removing else { return }
                do { try model.remove(orgID: row.id) } catch { removeError = "\(error)" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the key from this Mac. It still exists in Viam.")
        }
        .alert("Couldn't remove the key", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK") {}
        } message: {
            Text(removeError ?? "")
        }
    }

    private struct Instructions: Identifiable {
        let command: String
        var id: String { command }
    }

    static func describe(_ status: OrganizationsModel.Status) -> String {
        switch status {
        case .unchecked: "checking…"
        case .checked(let date):
            "checked \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))"
        case .rejected: "⚠ key rejected by Viam"
        case .unreachable: "couldn't reach Viam"
        }
    }

    static func isRejected(_ status: OrganizationsModel.Status) -> Bool {
        if case .rejected = status { return true }
        return false
    }
}
