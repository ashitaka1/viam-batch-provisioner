import Foundation
import ProvisionerKit
import Testing

private func event(_ name: String, _ kind: MachineEvent.Kind) -> MachineEvent {
    MachineEvent(id: 1, timestamp: Date(timeIntervalSince1970: 0), name: name, mac: "aa:bb:cc:dd:ee:ff", kind: kind)
}

struct InstallNotificationTests {
    @Test func completeNotifiesWithDuration() {
        let notification = InstallNotification(event("bench-3", .installComplete(duration: 725)))

        #expect(notification == InstallNotification(
            identifier: "install.bench-3", title: "bench-3 installed", subtitle: nil, body: "Installed in 12m 5s."))
    }

    @Test(arguments: [
        (45.0, "45s"),
        (59.6, "1m 0s"),
        (725.0, "12m 5s"),
        (3720.4, "1h 2m"),
    ])
    func durationFormats(seconds: Double, expected: String) {
        let notification = InstallNotification(event("m", .installComplete(duration: seconds)))

        #expect(notification?.body == "Installed in \(expected).")
    }

    @Test func failureCarriesReasonNameAndStage() {
        let notification = InstallNotification(
            event("bench-3", .installFailed(stage: "tooling", reason: "viam-agent download failed", source: .installer)))

        #expect(notification == InstallNotification(
            identifier: "install.bench-3", title: "bench-3 failed", subtitle: "Stage: tooling",
            body: "viam-agent download failed"))
    }

    @Test(arguments: [MachineEvent.FailureSource.installer, .timeout, .reboot])
    func failureFromEverySourceNotifies(source: MachineEvent.FailureSource) {
        let notification = InstallNotification(
            event("bench-3", .installFailed(stage: "unknown", reason: "no report for 45 minutes", source: source)))

        #expect(notification?.subtitle == "Stage: unknown")
        #expect(notification?.body == "no report for 45 minutes")
    }

    /// A later outcome for the same machine replaces the earlier notification.
    @Test func sameMachineSharesIdentifier() {
        let failed = InstallNotification(event("bench-3", .installFailed(stage: "unknown", reason: "r", source: .timeout)))
        let complete = InstallNotification(event("bench-3", .installComplete(duration: 1)))
        let other = InstallNotification(event("bench-4", .installComplete(duration: 1)))

        #expect(failed?.identifier == complete?.identifier)
        #expect(other?.identifier != complete?.identifier)
    }

    @Test(arguments: [
        MachineEvent.Kind.assigned,
        .installStarted,
        .installProgress(stage: "tooling"),
        .guardInstalled(reason: .repeatPXE),
    ])
    func otherKindsDoNotNotify(kind: MachineEvent.Kind) {
        #expect(InstallNotification(event("m", kind)) == nil)
    }
}
