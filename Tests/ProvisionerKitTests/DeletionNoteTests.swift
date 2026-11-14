@testable import ProvisionerKit
import Testing

@Suite struct DeletionNoteTests {
    private static let queued = "Machines already queued with it aren't affected."

    @Test(arguments: [
        (false, false, false, queued),
        (false, true, false, "Its WiFi password is removed from this Mac. " + queued),
        (true, false, true, "Its account password and Tailscale key are removed from this Mac. " + queued),
        (true, true, true, "Its account password, WiFi password and Tailscale key are removed from this Mac. " + queued),
    ])
    func namesOnlyTheSecretsItHolds(password: Bool, wifi: Bool, tailscale: Bool, note: String) {
        var environment = Environment.new(name: "Shop")
        environment.hasPassword = password
        environment.hasWifiPassword = wifi
        environment.hasTailscaleKey = tailscale
        #expect(environment.deletionNote == note)
    }
}
