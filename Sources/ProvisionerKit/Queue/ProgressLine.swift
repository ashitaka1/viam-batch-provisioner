/// A machine's progress in one line: a tone from its status and the step it is at.
public struct ProgressLine: Equatable, Sendable {
    public enum Tone: Sendable, Equatable { case waiting, active, installed, failed }

    public let tone: Tone
    public let text: String

    public init(tone: Tone, text: String) {
        self.tone = tone
        self.text = text
    }

    /// Without `progress` (the Python server), the status word and the installer's raw stage.
    public init(entry: QueueEntry, progress: ProvisioningProgress?) {
        tone = switch entry.status {
        case .queued, .flashed: .waiting
        case .assigned, .installing: .active
        case .installed: .installed
        case .failed: .failed
        }
        guard entry.status != .flashed else {
            text = "Flashed"
            return
        }
        guard let progress else {
            text = [Self.word(entry.status), entry.stage].compactMap { $0 }.joined(separator: " · ")
            return
        }
        let current = progress.current
        if current.state == .failed {
            let subStep = current.subSteps.first { $0.state == .failed }?.title
            text = ["Failed at \(current.title)", subStep].compactMap { $0 }.joined(separator: " · ")
            return
        }
        let detail: String? = switch current.kind {
        case .downloading: current.fraction.map { "\(Int(($0 * 100).rounded()))%" }
        case .installed where current.state == .current: "restarting"
        default: current.subSteps.first { $0.state == .current }?.title
        }
        text = [current.title, detail].compactMap { $0 }.joined(separator: " · ")
    }

    private static func word(_ status: EntryStatus) -> String {
        switch status {
        case .queued: "Queued"
        case .flashed: "Flashed"
        case .assigned: "Booting"
        case .installing: "Installing"
        case .installed: "Installed"
        case .failed: "Failed"
        }
    }
}
