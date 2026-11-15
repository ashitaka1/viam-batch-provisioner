import Foundation
import ProvisionerKit
import ServiceManagement
import Testing
@testable import ViamProvisioner

/// What the model asked of the daemon and the privileged runner, in order.
private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

/// A launch daemon whose status follows register and unregister unless told otherwise.
private final class FakeDaemon: DaemonService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SMAppService.Status
    let journal: Journal
    /// The status register leaves; `.requiresApproval` makes register throw, as SMAppService does.
    var registeredStatus: SMAppService.Status = .enabled
    var registerError: NSError?
    var unregisterError: NSError?

    init(_ status: SMAppService.Status = .notRegistered, journal: Journal) {
        current = status
        self.journal = journal
    }

    var status: SMAppService.Status { lock.withLock { current } }

    func register() throws {
        journal.add("register")
        if let registerError { throw registerError }
        lock.withLock { current = registeredStatus }
        if registeredStatus == .requiresApproval { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
    }

    func set(_ status: SMAppService.Status) { lock.withLock { current = status } }

    func unregister() async throws {
        journal.add("unregister")
        if let unregisterError { throw unregisterError }
        lock.withLock { current = .notRegistered }
    }
}

private final class ConflictBox: @unchecked Sendable {
    var value: ServerAccount.IDConflict?
}

private final class PathBox: @unchecked Sendable {
    var value: URL?
}

/// The server on the daemon's port, and launchd's record of its job.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: ServerAnswer = .answering
    private var _job: LaunchdJob?
    private(set) var asked = 0
    /// Runs while the server is being asked, before it answers.
    var whileAsked: (@Sendable () -> Void)?

    var answer: ServerAnswer {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    var job: LaunchdJob? {
        get { lock.withLock { _job } }
        set { lock.withLock { _job = newValue } }
    }

    func ask() -> ServerAnswer {
        whileAsked?()
        return lock.withLock {
            asked += 1
            return _answer
        }
    }
}

private struct Rig {
    let journal = Journal()
    let daemon: FakeDaemon
    let model: ServerDaemon
    let conflict = ConflictBox()
    let unreachable = PathBox()
    let server = FakeServer()

    @MainActor init(status: SMAppService.Status = .notRegistered, setUp: Bool = false, bundled: Bool = true,
                    unreachable: URL? = nil,
                    scriptError: PrivilegedScriptError? = nil, registeredStatus: SMAppService.Status = .enabled,
                    registerError: NSError? = nil, unregisterError: NSError? = nil) {
        let journal = journal
        daemon = FakeDaemon(status, journal: journal)
        daemon.registeredStatus = registeredStatus
        daemon.registerError = registerError
        daemon.unregisterError = unregisterError
        let conflict = conflict
        let unreachableBox = self.unreachable
        let server = server
        unreachableBox.value = unreachable
        model = ServerDaemon(
            service: daemon,
            isBundled: { bundled },
            isSetUp: { setUp },
            unreachablePath: { unreachableBox.value },
            conflict: { conflict.value },
            runPrivileged: { script in
                switch script {
                case ServerAccount.createScript(): journal.add("create script")
                case ServerAccount.removeScript(): journal.add("remove script")
                default: Issue.record("ran a script other than create or remove")
                }
                if let scriptError { throw scriptError }
            },
            askServer: { server.ask() },
            readJob: { server.job })
    }
}

private let failure = NSError(domain: "SMAppServiceErrorDomain", code: 22, userInfo: [NSLocalizedDescriptionKey: "Launchd refused."])

@MainActor @Test func firstEnableCreatesTheAccountThenRegisters() async {
    let rig = Rig()
    await rig.model.setHosting(true)
    #expect(rig.journal.all == ["create script", "register"])
    #expect(rig.model.state == .on)
}

@MainActor @Test func enableWhenSetUpRegistersWithoutAuthorization() async {
    let rig = Rig(setUp: true)
    await rig.model.setHosting(true)
    #expect(rig.journal.all == ["register"])
}

@MainActor @Test func cancelledEnableRegistersNothing() async {
    let rig = Rig(scriptError: .cancelled)
    await rig.model.setHosting(true)
    #expect(rig.journal.all == ["create script"])
    #expect(rig.model.state == .off)
    #expect(rig.model.note == "The server wasn't set up.")
}

@MainActor @Test func failedEnableShowsTheScriptsMessage() async {
    let rig = Rig(scriptError: .failed("No ID between 401 and 499 is free for _viamprovisioner."))
    await rig.model.setHosting(true)
    #expect(rig.journal.all == ["create script"])
    #expect(rig.model.note == "No ID between 401 and 499 is free for _viamprovisioner.")
}

@MainActor @Test func pendingApprovalIsNotAnError() async {
    let rig = Rig(setUp: true, registeredStatus: .requiresApproval)
    await rig.model.setHosting(true)
    #expect(rig.model.state == .needsApproval)
    #expect(rig.model.note == nil)
}

@MainActor @Test func turningHostingOffUnregistersAndRunsNoScript() async {
    let rig = Rig(status: .enabled, setUp: true)
    await rig.model.setHosting(false)
    #expect(rig.journal.all == ["unregister"])
    #expect(rig.model.state == .off)
}

@MainActor @Test func removeUnregistersBeforeTheRemoveScript() async {
    let rig = Rig(status: .enabled, setUp: true)
    await rig.model.removeServerData()
    #expect(rig.journal.all == ["unregister", "remove script"])
    #expect(rig.model.state == .off)
    #expect(rig.model.note == nil)
}

@MainActor @Test func removeWithHostingAlreadyOffStillRunsTheScript() async {
    let rig = Rig(status: .notRegistered, setUp: true)
    await rig.model.removeServerData()
    #expect(rig.journal.all == ["remove script"])
}

@MainActor @Test func cancelledRemoveKeepsDataAndSaysSo() async {
    let rig = Rig(status: .enabled, setUp: true, scriptError: .cancelled)
    await rig.model.removeServerData()
    #expect(rig.model.state == .off)
    #expect(rig.model.note == "Server data and the _viamprovisioner account were kept.")
}

@MainActor @Test func stateFollowsTheDaemonsStatus() {
    for (status, state) in [(SMAppService.Status.enabled, ServerDaemonState.on), (.requiresApproval, .needsApproval),
                            (.notFound, .off), (.notRegistered, .off)] {
        let rig = Rig(status: status)
        #expect(rig.model.state == state, "status \(status.rawValue) should read as \(state)")
    }
}

@MainActor @Test func notFoundIsMissingOnlyWhenTheBundleLacksThePlist() {
    // SMAppService reports .notFound for a daemon that was never registered, too.
    #expect(Rig(status: .notFound, bundled: true).model.state == .off)
    #expect(Rig(status: .notFound, bundled: false).model.state == .missing)
}

@MainActor @Test func refreshPicksUpAChangeMadeInSystemSettings() {
    let rig = Rig(status: .requiresApproval)
    rig.daemon.set(.enabled)
    rig.model.refresh()
    #expect(rig.model.state == .on)
}

@MainActor @Test func registerFailureOtherThanApprovalIsShown() async {
    let rig = Rig(setUp: true, registerError: failure)
    await rig.model.setHosting(true)
    #expect(rig.model.state == .off)
    #expect(rig.model.note == "Launchd refused.")
}

@MainActor @Test func unregisterFailureWhenTurningOffIsShown() async {
    let rig = Rig(status: .enabled, setUp: true, unregisterError: failure)
    await rig.model.setHosting(false)
    #expect(rig.model.note == "Launchd refused.")
}

@MainActor @Test func removeUnregistersADaemonAwaitingApproval() async {
    let rig = Rig(status: .requiresApproval, setUp: true)
    await rig.model.removeServerData()
    #expect(rig.journal.all == ["unregister", "remove script"])
}

@MainActor @Test func removeStopsBeforeTheScriptWhenUnregisterFails() async {
    // Deleting the account under a daemon that's still registered would leave launchd starting it as no one.
    let rig = Rig(status: .enabled, setUp: true, unregisterError: failure)
    await rig.model.removeServerData()
    #expect(rig.journal.all == ["unregister"])
    #expect(rig.model.note == "Launchd refused.")
}

@MainActor @Test func sharedIDIsReportedOnRefresh() {
    let rig = Rig(status: .enabled, setUp: true)
    #expect(rig.model.conflict == nil)
    rig.conflict.value = ServerAccount.IDConflict(id: 499, users: ["_newdaemon"], groups: [])
    rig.model.refresh()
    #expect(rig.model.conflict == ServerAccount.IDConflict(id: 499, users: ["_newdaemon"], groups: []))
}

private func osascript(_ source: String) throws -> (status: Int32, output: String, error: String) {
    let process = Process(), output = Pipe(), error = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let out = output.fileHandleForReading.readDataToEndOfFile(), err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
}

@Test(arguments: [ServerAccount.createScript(), ServerAccount.removeScript(), #"a "quoted" \back\slash\n and 'single'"#])
func administratorScriptReachesTheShellUnchanged(script: String) throws {
    // The administrator prompt runs `do shell script <literal>`; the literal must decode to the script byte for byte.
    let source = ServerDaemon.appleScriptSource(for: script)
    let prefix = "do shell script ", suffix = " with administrator privileges"
    #expect(source.hasPrefix(prefix) && source.hasSuffix(suffix), "unexpected shape: \(source)")
    let literal = source.dropFirst(prefix.count).dropLast(suffix.count)
    let result = try osascript("return \(literal)")
    #expect(result.status == 0, "AppleScript rejected the literal: \(result.error)")
    #expect(result.output == script + "\n")
}

@Test func cancellingTheAdministratorPromptIsACancel() {
    #expect(PrivilegedScriptError(appleScriptError: [NSAppleScript.errorNumber: -128, NSAppleScript.errorMessage: "User canceled."]) == .cancelled)
}

@Test func otherAdministratorScriptErrorsCarryTheShellsMessage() {
    #expect(PrivilegedScriptError(appleScriptError: [NSAppleScript.errorNumber: 1, NSAppleScript.errorMessage: "No ID between 401 and 499 is free for _viamprovisioner."])
        == .failed("No ID between 401 and 499 is free for _viamprovisioner."))
}

@MainActor @Test func enableRefusesWhenTheServerCantOpenTheApp() async {
    let rig = Rig(unreachable: URL(filePath: "/Users/someone"))
    #expect(rig.model.unreachablePath?.path == "/Users/someone")
    await rig.model.setHosting(true)
    #expect(rig.journal.all.isEmpty, "set up or registered a daemon that can't start: \(rig.journal.all)")
    #expect(rig.model.state == .off)
    #expect(rig.model.note == rig.model.unreachableMessage)
}

@MainActor @Test func hostingTurnsOffWhenTheServerCantOpenTheApp() async {
    let rig = Rig(status: .enabled, setUp: true, unreachable: URL(filePath: "/Users/someone"))
    await rig.model.setHosting(false)
    #expect(rig.journal.all == ["unregister"])
    #expect(rig.model.state == .off)
}

@MainActor @Test func unreachableMessageSaysWhereToMoveTheApp() {
    let rig = Rig(unreachable: URL(filePath: "/Users/someone"))
    #expect(rig.model.unreachableMessage == "Move Viam Provisioner to the Applications folder to turn on server mode. The server runs as _viamprovisioner, which can't open /Users/someone.")
}

@MainActor @Test func appMovedOutOfReachWhileHostingSaysTheServerCantStart() {
    let rig = Rig(status: .enabled, setUp: true)
    #expect(!rig.model.cantStart)
    rig.unreachable.value = URL(filePath: "/Users/someone")
    rig.model.refresh()
    #expect(rig.model.cantStart)
    #expect(rig.model.unreachableMessage == "The server can't start: it runs as _viamprovisioner, which can't open /Users/someone. Move Viam Provisioner to the Applications folder.")
}

@MainActor @Test func unreachableAppAwaitingApprovalSaysTheServerCantStart() {
    let rig = Rig(status: .requiresApproval, setUp: true, unreachable: URL(filePath: "/Users/someone"))
    #expect(rig.model.cantStart)
}

@MainActor @Test func unreachableAppWithHostingOffIsNotAStartFailure() {
    let rig = Rig(unreachable: URL(filePath: "/Users/someone"))
    #expect(!rig.model.cantStart)
}

private let printedCrashLoop = """
    system/com.bringingfire.viam-provisioner.server = {
    \tactive count = 0
    \tstate = spawn scheduled

    \tresource coalition = {
    \t\tstate = active
    \t}
    \truns = 14
    \tpid = 0
    \tlast exit code = 1
    }
    """

@Test func launchdJobReadsRunsAndTheLastExit() {
    #expect(LaunchdJob(launchctlPrint: printedCrashLoop) == LaunchdJob(runs: 14, lastExitCode: "1"))
}

@Test func launchdJobThatNeverExitedHasNoExitCode() {
    let job = LaunchdJob(launchctlPrint: "\truns = 1\n\tlast exit code = (never exited)\n")
    #expect(job.lastExitCode == nil)
    #expect(job.reason == nil)
}

@Test func launchdReasonPrefersTheTerminatingSignal() {
    // A killed job also records exit code 0, which alone would read as a clean exit.
    let job = LaunchdJob(launchctlPrint: "\truns = 3\n\tlast exit code = 0\n\tlast terminating signal = Killed: 9\n")
    #expect(job.lastSignal == "Killed: 9")
    #expect(job.reason?.contains("Killed: 9") == true)
    #expect(job.reason?.contains("code 0") == false)
}

@Test func refusedConnectionIsSilentAndAnyOtherReplyIsAnotherProcess() {
    #expect(ServerAnswer(.transport(URLError(.cannotConnectToHost))) == .silent)
    #expect(ServerAnswer(.unexpectedResponse(status: 404)) == .otherProcess)
    #expect(ServerAnswer(.server(status: 503, code: "unavailable", message: "Data directory unreadable.", details: [])) == .failing("Data directory unreadable."))
}

@MainActor @Test func serverAnsweringWithItsErrorIsNotBlamedOnAnotherProcess() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .failing("Data directory unreadable.")
    await rig.model.check()
    #expect(rig.model.notAnsweringMessage == "The server isn't answering. It answered: Data directory unreadable.")
}

@MainActor @Test func serverIsNotAskedWhenLaunchdCantStartIt() async {
    // The unreachable-app message already says why; a second warning would repeat it.
    let rig = Rig(status: .enabled, setUp: true, unreachable: URL(filePath: "/Users/someone"))
    await rig.model.check()
    #expect(rig.server.asked == 0)
    #expect(rig.model.serving == nil)
}

@MainActor @Test func registeredServerThatAnswersReadsRunning() async {
    let rig = Rig(status: .enabled, setUp: true)
    await rig.model.check()
    #expect(rig.model.serving == .answering)
    #expect(rig.model.notAnsweringMessage == nil)
}

@MainActor @Test func registeredServerThatDoesntAnswerSaysWhatLaunchdRecorded() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .silent
    rig.server.job = LaunchdJob(runs: 14, lastExitCode: "1")
    await rig.model.check()
    #expect(rig.model.notAnsweringMessage == "The server isn't answering. launchd has started it 14 times; it last exited with code 1.")
}

@MainActor @Test func anotherProcessOnThePortIsNamed() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .otherProcess
    rig.server.job = LaunchdJob(runs: 2, lastExitCode: "1")
    await rig.model.check()
    #expect(rig.model.notAnsweringMessage == "The server isn't answering. Another process answers on port 8234. launchd has started it 2 times; it last exited with code 1.")
}

@MainActor @Test func notAnsweringWithoutALaunchdRecordSaysOnlyThat() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .silent
    await rig.model.check()
    #expect(rig.model.notAnsweringMessage == "The server isn't answering.")
}

@MainActor @Test func serverThatAnswersAgainReadsRunningOnTheNextCheck() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .otherProcess
    await rig.model.check()
    #expect(rig.model.serving == .notAnswering(reason: "Another process answers on port 8234."))
    rig.server.answer = .answering
    await rig.model.check()
    #expect(rig.model.serving == .answering)
}

@MainActor @Test func serverIsNotAskedWhileHostingIsOff() async {
    let rig = Rig(status: .requiresApproval, setUp: true)
    await rig.model.check()
    #expect(rig.server.asked == 0)
    #expect(rig.model.serving == nil)
}

@MainActor @Test func turningHostingOffClearsTheServersState() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .silent
    await rig.model.check()
    await rig.model.setHosting(false)
    #expect(rig.model.serving == nil)
}

@MainActor @Test func hostingTurnedOffWhileTheServerIsAskedLeavesNoState() async {
    let rig = Rig(status: .enabled, setUp: true)
    rig.server.answer = .silent
    let daemon = rig.daemon
    rig.server.whileAsked = { daemon.set(.notRegistered) }
    await rig.model.check()
    #expect(rig.model.serving == nil)
}
