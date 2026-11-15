import ProvisionerKit
import Testing
@testable import ViamProvisioner

private let conflict = ServerAccount.IDConflict(id: 499, users: [], groups: ["_qatest"])
private let cantStart = "The server can't start: it runs as _viamprovisioner, which can't open /Users/someone. Move Viam Provisioner to the Applications folder."

@Test func cleanStatusExitsZero() {
    let report = ServerDaemonCommand.report(state: .on, note: nil, conflict: nil, cantStart: nil)
    #expect(report == .init(errors: [], status: "server daemon: enabled", exitCode: 0))
}

@Test(arguments: [
    (note: "The server wasn't set up." as String?, conflict: nil as ServerAccount.IDConflict?, cantStart: nil as String?),
    (note: nil, conflict: conflict, cantStart: nil),
    (note: nil, conflict: nil, cantStart: cantStart),
])
func eachProblemIsPrintedAndExitsOne(note: String?, conflict: ServerAccount.IDConflict?, cantStart: String?) {
    let report = ServerDaemonCommand.report(state: .on, note: note, conflict: conflict, cantStart: cantStart)
    #expect(report.exitCode == 1)
    #expect(report.errors == [note, conflict?.message, cantStart].compactMap { $0 })
}

@Test func aCantStartNoteIsPrintedOnce() {
    let report = ServerDaemonCommand.report(state: .on, note: cantStart, conflict: nil, cantStart: cantStart)
    #expect(report.errors == [cantStart])
    #expect(report.exitCode == 1)
}

@Test func everyStateIsDescribed() {
    #expect(ServerDaemonCommand.report(state: .off, note: nil, conflict: nil, cantStart: nil).status == "server daemon: not registered")
    #expect(ServerDaemonCommand.report(state: .missing, note: nil, conflict: nil, cantStart: nil).status == "server daemon: missing from the app bundle")
    #expect(ServerDaemonCommand.report(state: .needsApproval, note: nil, conflict: nil, cantStart: nil).status.hasPrefix("server daemon: registered; turn it on"))
}

@Test func statusFailsWhenTheRegisteredServerIsntAnswering() {
    let report = ServerDaemonCommand.report(state: .on, note: nil, conflict: nil, cantStart: nil,
                                            notAnswering: "The server isn't answering.")
    #expect(report.errors == ["The server isn't answering."])
    #expect(report.exitCode == 1)
}
