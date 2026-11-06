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
        (#"{"id":1,"type":"install-failed","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","stage":"late-commands","reason":"booted again","source":"reboot"}"#,
         .installFailed(stage: "late-commands", reason: "booted again", source: .reboot)),
        (#"{"id":1,"type":"guard-installed","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","reason":"repeat-pxe"}"#,
         .guardInstalled(reason: .repeatPXE)),
        (#"{"id":1,"type":"guard-installed","timestamp":"\#(stamp)","name":"m1","mac":"\#(mac)","reason":"hostname-fetch"}"#,
         .guardInstalled(reason: .hostnameFetch)),
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

@Test func installCompleteWithoutMAC() throws {
    let complete = try event(#"{"id":5,"type":"install-complete","timestamp":"\#(stamp)","name":"usb1","duration_seconds":42}"#)
    let expected = MachineEvent(id: 5, timestamp: utc(2026, 10, 4, 4, 8, 29), name: "usb1", mac: nil, kind: .installComplete(duration: 42))
    #expect(complete == .machine(expected))
}

@Test func queueEntryMapsAllFields() throws {
    let wire = try decode(Components.Schemas.QueueEntry.self, """
        {"name":"usb1","status":"failed","mac":"\(mac)","assigned_at":"\(stamp)","completed_at":"\(stamp)",
         "failed_at":"\(stamp)","failure_reason":"disk","stage":"late-commands","warning":"moved","has_credentials":true,"flashed_via":"usb"}
        """)
    let date = utc(2026, 10, 4, 4, 8, 29)
    #expect(QueueEntry(wire) == QueueEntry(
        name: "usb1", status: .failed, mac: mac, assignedAt: date, completedAt: date, failedAt: date,
        failureReason: "disk", stage: "late-commands", warning: "moved", hasCredentials: true, flashedViaUSB: true))
}

@Test(arguments: [
    #"{"cloud":{"id":"part-1"}}"#,
    #"{"cloud":{"id":"part-1","secret":""}}"#,
    #"{"cloud":{"id":"","secret":"s"}}"#,
    #"{"id":"part-1","secret":"s"}"#,
    "not json",
])
func rejectsCredentialsThatAreNotAViamJSON(json: String) {
    let request = ProvisionRequest(name: "m1", credentialsJSON: Data(json.utf8))
    #expect(throws: ProvisionerError.invalidCredentials, "credentials \(json)") { try request.wire() }
}
