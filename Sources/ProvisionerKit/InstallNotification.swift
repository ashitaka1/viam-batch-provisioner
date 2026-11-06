import Foundation

/// What to tell the operator when an install ends.
public struct InstallNotification: Sendable, Equatable {
    /// One per machine: a later outcome replaces the earlier notification.
    public var identifier: String
    public var title: String
    public var subtitle: String?
    public var body: String

    public init(identifier: String, title: String, subtitle: String?, body: String) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// Nil for events that don't end an install.
    public init?(_ event: MachineEvent) {
        let identifier = "install.\(event.name)"
        switch event.kind {
        case .installComplete(let duration):
            self.init(identifier: identifier, title: "\(event.name) installed", subtitle: nil,
                      body: "Installed in \(Self.format(duration)).")
        case .installFailed(let stage, let reason, _):
            self.init(identifier: identifier, title: "\(event.name) failed", subtitle: "Stage: \(stage)", body: reason)
        case .assigned, .installStarted, .installProgress, .guardInstalled, .stepReached, .downloadProgress:
            return nil
        }
    }

    private static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        let (hours, minutes) = (seconds / 3600, seconds % 3600 / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
