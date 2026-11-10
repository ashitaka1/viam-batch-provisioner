public import Foundation

/// The rows a machine's provisioning timeline shows: reached steps with their
/// times, then the steps after the latest one as pending. Steps skipped before it are omitted: nothing is inferred.
public struct ProvisioningProgress: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case queued, found, booting, downloading, installing, configuring, installed, viamOnline }
    public enum State: Sendable, Equatable { case done, current, failed, pending }

    public struct SubStep: Sendable, Equatable {
        public var title: String
        public var state: State
    }

    public struct Row: Sendable, Equatable {
        public var kind: Kind
        public var title: String
        public var at: Date?
        public var state: State
        public var subSteps: [SubStep] = []
        public var fraction: Double?
    }

    /// The current attempt, from Queued to the last step.
    public let rows: [Row]
    /// The reached steps of each earlier attempt, oldest first.
    public let earlierAttempts: [[Row]]

    /// The row in progress or failed, else the last one done.
    public var current: Row {
        rows.first { $0.state == .current || $0.state == .failed } ?? rows.last { $0.state == .done } ?? rows[0]
    }

    /// Nil for an entry with no steps and no queued time, such as one from the Python server.
    /// `onlineAt` counts only once the entry has reached Installed.
    public init?(entry: QueueEntry, onlineAt: Date? = nil) {
        guard !entry.steps.isEmpty || entry.queuedAt != nil else { return nil }
        let attempts = Array(Set(entry.steps.map(\.attempt))).sorted()
        let latest = attempts.last
        let reached = entry.steps.filter { $0.attempt == latest }
        let failed = entry.status == .failed

        func title(_ step: ProvisioningStep) -> String { step.title(osName: entry.osName) }
        func kind(_ step: ProvisioningStep) -> Kind {
            switch step {
            case .found: .found
            case .booting: .booting
            case .downloading: .downloading
            case .installing: .installing
            case .configuring: .configuring
            case .installed: .installed
            }
        }

        var rows = [Row(kind: .queued, title: "Queued", at: entry.queuedAt, state: reached.isEmpty ? .current : .done)]
        rows += reached.map { Row(kind: kind($0.step), title: title($0.step), at: $0.at, state: .done) }
        let reachedSteps = Set(reached.map(\.step))
        let order = ProvisioningStep.allCases
        let failureStep = failed ? entry.failureStep : nil
        let anchor = (reachedSteps.union(failureStep.map { [$0] } ?? [])).compactMap { order.firstIndex(of: $0) }.max()
        let pending = order.enumerated().filter { index, _ in anchor.map { index > $0 } ?? true }.map(\.element)
        if let last = rows.indices.last { rows[last].state = .current }

        if failed {
            if let step = entry.failureStep, let index = rows.firstIndex(where: { $0.kind == kind(step) }) {
                rows[index].state = .failed
            } else if let step = entry.failureStep {
                let row = Row(kind: kind(step), title: title(step), at: entry.failedAt, state: .failed)
                let later = rows.firstIndex { r in
                    ProvisioningStep.allCases.contains { kind($0) == r.kind && order.firstIndex(of: $0)! > order.firstIndex(of: step)! }
                }
                rows.insert(row, at: later ?? rows.endIndex)
            } else if let last = rows.indices.last {
                rows[last].state = .failed
            }
            for index in rows.indices where rows[index].state == .current { rows[index].state = .done }
        }

        rows += pending.map { Row(kind: kind($0), title: title($0), at: nil, state: .pending) }
        let installed = reachedSteps.contains(.installed)
        if entry.provisionMode == .full {
            let online = installed ? onlineAt : nil
            rows.append(Row(kind: .viamOnline, title: "Viam online", at: online, state: online == nil ? .pending : .done))
            if online != nil {
                for index in rows.indices where rows[index].state == .current { rows[index].state = .done }
            }
        } else if installed, !failed, let index = rows.firstIndex(where: { $0.kind == .installed }) {
            rows[index].state = .done
        }

        for index in rows.indices {
            switch rows[index].kind {
            case .downloading where rows[index].state == .current:
                rows[index].fraction = Self.fraction(bytes: entry.downloadBytes, total: entry.downloadTotal)
            case .configuring:
                rows[index].subSteps = Self.subSteps(entry, row: rows[index])
            default: break
            }
        }

        self.rows = rows
        self.earlierAttempts = attempts.dropLast().map { attempt in
            entry.steps.filter { $0.attempt == attempt }.map { Row(kind: kind($0.step), title: title($0.step), at: $0.at, state: .done) }
        }
    }

    /// Downloaded share clamped to 0...1; nil without a positive total.
    public static func fraction(bytes: Int?, total: Int?) -> Double? {
        guard let bytes, let total, total > 0 else { return nil }
        return min(max(Double(bytes) / Double(total), 0), 1)
    }

    /// None once Configuring is done: the record keeps no history of the installer's stages.
    private static func subSteps(_ entry: QueueEntry, row: Row) -> [SubStep] {
        guard row.state != .done else { return [] }
        var titles = ["Setting name and credentials"]
        if entry.provisionMode == .full || entry.provisionMode == .agent { titles.append("Installing Viam") }
        if entry.joinsTailscale == true { titles.append("Joining Tailscale") }
        let currentTitle: String? = switch entry.stage {
        case "late-commands", "identity": titles[0]
        case "tooling": "Installing Viam"
        case "tailscale": "Joining Tailscale"
        default: nil
        }
        let currentIndex = currentTitle.flatMap { titles.firstIndex(of: $0) }
        return titles.enumerated().map { index, title in
            let state: State
            if row.state == .pending {
                state = .pending
            } else if let currentIndex {
                state = index < currentIndex ? .done : index == currentIndex ? (row.state == .failed ? .failed : .current) : .pending
            } else {
                state = .pending
            }
            return SubStep(title: title, state: state)
        }
    }
}
