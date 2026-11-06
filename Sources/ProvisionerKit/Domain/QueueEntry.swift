public import Foundation
internal import ProvisionerAPI

public enum EntryStatus: String, Sendable, Equatable, CaseIterable {
    case queued, flashed, assigned, installing, installed, failed
}

public struct StepTime: Sendable, Equatable {
    public var step: ProvisioningStep
    public var at: Date
    public var attempt: Int

    public init(step: ProvisioningStep, at: Date, attempt: Int) {
        self.step = step
        self.at = at
        self.attempt = attempt
    }
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
    public var hasCredentials: Bool
    public var flashedViaUSB: Bool
    public var queuedAt: Date?
    public var steps: [StepTime]
    public var osName: String?
    public var downloadBytes: Int?
    public var downloadTotal: Int?
    public var failureStep: ProvisioningStep?
    public var provisionMode: ProvisionMode?
    public var joinsTailscale: Bool?

    public var id: String { name }

    public init(
        name: String, status: EntryStatus, mac: String? = nil, assignedAt: Date? = nil, completedAt: Date? = nil,
        failedAt: Date? = nil, failureReason: String? = nil, stage: String? = nil, hasCredentials: Bool,
        flashedViaUSB: Bool = false, queuedAt: Date? = nil, steps: [StepTime] = [], osName: String? = nil,
        downloadBytes: Int? = nil, downloadTotal: Int? = nil, failureStep: ProvisioningStep? = nil,
        provisionMode: ProvisionMode? = nil, joinsTailscale: Bool? = nil
    ) {
        self.name = name
        self.status = status
        self.mac = mac
        self.assignedAt = assignedAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.failureReason = failureReason
        self.stage = stage
        self.hasCredentials = hasCredentials
        self.flashedViaUSB = flashedViaUSB
        self.queuedAt = queuedAt
        self.steps = steps
        self.osName = osName
        self.downloadBytes = downloadBytes
        self.downloadTotal = downloadTotal
        self.failureStep = failureStep
        self.provisionMode = provisionMode
        self.joinsTailscale = joinsTailscale
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
            hasCredentials: wire.hasCredentials,
            flashedViaUSB: wire.flashedVia == .usb,
            queuedAt: wire.queuedAt,
            steps: (wire.steps ?? []).compactMap { step in
                ProvisioningStep(rawValue: step.step.rawValue).map { StepTime(step: $0, at: step.at, attempt: step.attempt) }
            },
            osName: wire.osName,
            downloadBytes: wire.downloadBytes,
            downloadTotal: wire.downloadTotal,
            failureStep: wire.failureStep.flatMap { ProvisioningStep(rawValue: $0.rawValue) },
            provisionMode: wire.provisionMode.flatMap { ProvisionMode(rawValue: $0.rawValue) },
            joinsTailscale: wire.joinsTailscale
        )
    }
}
