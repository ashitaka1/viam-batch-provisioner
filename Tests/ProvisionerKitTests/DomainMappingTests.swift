import Foundation
import ProvisionerAPI
@testable import ProvisionerKit
import Testing

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try WireCoding.decoder.decode(type, from: Data(json.utf8))
}

private func event(_ json: String) throws -> WireEvent {
    try WireEvent(decode(Components.Schemas.MachineEvent.self, json))
}

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

private let mac = "aa:bb:cc:dd:ee:ff"
private let stamp = "2026-10-04T04:08:29+00:00"

@Test func everyEventTypeMaps() throws {
    let cases: [(String, MachineEvent.Kind)] = [
        (#"{"id":1,"type":"machine-assigned","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)"}"#, .assigned),
        (#"{"id":1,"type":"install-started","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","stage":"late-commands"}"#, .installStarted),
        (#"{"id":1,"type":"install-progress","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","stage":"late-commands"}"#,
         .installProgress(stage: "late-commands")),
        (#"{"id":1,"type":"install-failed","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","stage":"late-commands","reason":"no activity","source":"timeout"}"#,
         .installFailed(stage: "late-commands", reason: "no activity", source: .timeout)),
        (#"{"id":1,"type":"install-complete","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","duration_seconds":812.5}"#,
         .installComplete(duration: 812.5)),
        (#"{"id":1,"type":"guard-installed","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","reason":"repeat-pxe"}"#,
         .guardInstalled(reason: .repeatPXE)),
    ]
    for (json, kind) in cases {
        let expected = MachineEvent(id: 1, timestamp: utc(2026, 10, 4, 4, 8, 29), name: "m1", mac: mac, kind: kind)
        #expect(try event(json) == .machine(expected), "decoding \(json)")
    }
    #expect(try event(#"{"type":"resync","latest_id":42}"#) == .resync(latestID: 42))
}

@Test func usbEventsHaveNoMAC() throws {
    let progress = try event(#"{"id":3,"type":"install-progress","timestamp":"\#(stamp)","name":"usb1","stage":"late-commands"}"#)
    let failed = try event(#"{"id":4,"type":"install-failed","timestamp":"\#(stamp)","name":"usb1","stage":"late-commands","reason":"r","source":"installer"}"#)
    guard case .machine(let p) = progress, case .machine(let f) = failed else {
        Issue.record("expected machine events, got \(progress) and \(failed)")
        return
    }
    #expect(p.mac == nil)
    #expect(f.mac == nil)
}

@Test func specTimestampsDecode() throws {
    let expected = utc(2026, 10, 4, 4, 8, 29)
    for stamp in ["2026-10-04T04:08:29+00:00", "2026-10-04T00:08:29-04:00"] {
        let wire = try decode(Components.Schemas.QueueEntry.self,
                              #"{"name":"m1","status":"assigned","has_credentials":false,"assigned_at":"\#(stamp)"}"#)
        #expect(QueueEntry(wire).assignedAt == expected, "decoding \(stamp)")
    }
}

@Test func queueEntryMapsAllFields() throws {
    let wire = try decode(Components.Schemas.QueueEntry.self, """
        {"name":"usb1","status":"failed","mac":"\(mac)","assigned_at":"\(stamp)","completed_at":"\(stamp)",
         "failed_at":"\(stamp)","failure_reason":"disk","stage":"late-commands","has_credentials":true,"flashed_via":"usb"}
        """)
    let date = utc(2026, 10, 4, 4, 8, 29)
    #expect(QueueEntry(wire) == QueueEntry(
        name: "usb1", status: .failed, mac: mac, assignedAt: date, completedAt: date, failedAt: date,
        failureReason: "disk", stage: "late-commands", hasCredentials: true, flashedViaUSB: true))
}

private let viamJSON = Data(#"{"cloud":{"app_address":"https://app.viam.com:443","id":"part-1","secret":"s3cr3t"}}"#.utf8)

@Test func environmentRoundTrip() throws {
    let environment = EnvironmentConfig(
        provisionMode: .osOnly, username: "viam", passwordHash: "$6$salt$hash", sshPublicKey: "ssh-ed25519 AAAA",
        timezone: "America/New_York", packages: [], wifi: .init(ssid: "lab", password: nil, country: "US"),
        tailscaleAuthKey: nil)
    let request = ProvisionRequest(name: "m1", credentialsJSON: viamJSON, environment: environment)

    let encoded = try WireCoding.encoder.encode(request.wire())
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let env = try #require(object["environment"] as? [String: Any])
    let wifi = try #require(env["wifi"] as? [String: Any])
    let credentials = try #require(object["credentials"] as? [String: Any])

    #expect(env["provision_mode"] as? String == "os-only")
    #expect(env["password_hash"] as? String == "$6$salt$hash")
    #expect(env["packages"] == nil, "empty packages should be absent, got \(env["packages"] ?? "nil")")
    #expect(env["tailscale_auth_key"] == nil)
    #expect(wifi["ssid"] as? String == "lab")
    #expect(wifi["password"] == nil, "nil wifi password should be absent")
    #expect((credentials["cloud"] as? [String: Any])?["secret"] as? String == "s3cr3t")
}

@Test func rejectsCredentialsWithoutSecret() {
    let request = ProvisionRequest(name: "m1", credentialsJSON: Data(#"{"cloud":{"id":"part-1"}}"#.utf8), environment: nil)
    #expect(throws: ProvisionerError.invalidCredentials) { try request.wire() }
}

@Test func serverStatusMaps() throws {
    let wire = try decode(Components.Schemas.ServerStatus.self, """
        {"api_version":"v1","server_name":"lab-mac","time":"\(stamp)","address":"10.0.0.2:8234",
         "queue":{"queued":1,"flashed":0,"assigned":2,"installing":0,"installed":3,"failed":1,"total":7},
         "services":{"http":"up","dnsmasq":"down","watcher":"unknown"},"last_event_id":9}
        """)
    let status = ServerStatus(wire)
    #expect(status.serverName == "lab-mac")
    #expect(status.queue?.total == 7)
    #expect(status.services == .init(http: .up, dnsmasq: .down, watcher: .unknown))
    #expect(status.lastEventID == 9)
}
