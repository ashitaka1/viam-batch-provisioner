public import Foundation
internal import ProvisionerAPI

public enum EntryStatus: String, Sendable, Equatable, CaseIterable {
    case queued, flashed, assigned, installing, installed, failed
}

public struct QueueEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var status: EntryStatus
    public var mac: String?
    public var assignedAt: Date?
    public var completedAt: Date?
    public var failedAt: Date?
    public var failureReason: String?
    public var stage: String?
    /// The warning the installer's `done` report carried.
    public var warning: String?
    public var hasCredentials: Bool
    public var flashedViaUSB: Bool

    public var id: String { name }

    public init(
        name: String, status: EntryStatus, mac: String? = nil, assignedAt: Date? = nil, completedAt: Date? = nil,
        failedAt: Date? = nil, failureReason: String? = nil, stage: String? = nil, warning: String? = nil, hasCredentials: Bool,
        flashedViaUSB: Bool = false
    ) {
        self.name = name
        self.status = status
        self.mac = mac
        self.assignedAt = assignedAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.failureReason = failureReason
        self.stage = stage
        self.warning = warning
        self.hasCredentials = hasCredentials
        self.flashedViaUSB = flashedViaUSB
    }

    init(_ wire: Components.Schemas.QueueEntry) {
        self.init(
            name: wire.name,
            status: EntryStatus(rawValue: wire.status.rawValue)!,
            mac: wire.mac,
            assignedAt: wire.assignedAt,
            completedAt: wire.completedAt,
            failedAt: wire.failedAt,
            failureReason: wire.failureReason,
            stage: wire.stage?.rawValue,
            warning: wire.warning,
            hasCredentials: wire.hasCredentials,
            flashedViaUSB: wire.flashedVia == .usb
        )
    }
}
