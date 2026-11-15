import Foundation
@testable import ProvisionerKit
import Testing

/// A temporary directory holding fake `dscl` and `chown` scripts that log their arguments, and the
/// server directory the scripts under test act on. `dscl -read` succeeds only when `read` exists,
/// printing it; `dscl -list` prints `users` or `groups`.
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "server-account-\(UUID().uuidString)")
    var serverDirectory: URL { root.appending(path: "Library/Application Support/Viam Provisioner/Server") }
    var dscl: String { root.appending(path: "dscl").path }
    var chown: String { root.appending(path: "chown").path }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("dscl", """
            #!/bin/sh
            echo "dscl $*" >> '\(root.path)/log'
            case "$2" in
            -read) [ -f '\(root.path)/read' ] || exit 56; cat '\(root.path)/read' ;;
            -list) [ "$3" = /Users ] && cat '\(root.path)/users' 2>/dev/null; [ "$3" = /Groups ] && cat '\(root.path)/groups' 2>/dev/null; exit 0 ;;
            -delete) [ -f '\(root.path)/read' ] || exit 56 ;;
            esac
            exit 0
            """, executable: true)
        try write("chown", "#!/bin/sh\necho \"chown $*\" >> '\(root.path)/log'\n", executable: true)
    }

    func write(_ name: String, _ text: String, executable: Bool = false) throws {
        let url = root.appending(path: name)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    var log: [String] {
        ((try? String(contentsOf: root.appending(path: "log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        let errors = root.appending(path: "stderr")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let handle = try FileHandle(forWritingTo: errors)
        defer { try? handle.close() }
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// What the last `run` wrote to standard error.
    var errors: String {
        (try? String(contentsOf: root.appending(path: "stderr"), encoding: .utf8)) ?? ""
    }

    func create() throws -> Int32 {
        try run(ServerAccount.createScript(dscl: dscl, chown: chown, serverDirectory: serverDirectory))
    }

    func remove() throws -> Int32 {
        try run(ServerAccount.removeScript(dscl: dscl, serverDirectory: serverDirectory))
    }

    func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func createMakesGroupThenHiddenUserWithHighestFreeID() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("users", "root 0\n_www 70\nfoo 499\nbaz 401\n")
    try sandbox.write("groups", "bar 498\n")

    #expect(try sandbox.create() == 0)

    let log = sandbox.log
    let group = log.firstIndex(of: "dscl . -create /Groups/_viamprovisioner PrimaryGroupID 497")
    let user = log.firstIndex(of: "dscl . -create /Users/_viamprovisioner UniqueID 497")
    #expect(group != nil, "no group created with ID 497 in \(log)")
    #expect(user != nil, "no user created with ID 497 in \(log)")
    if let group, let user { #expect(group < user, "the user was created before its group") }
    for line in ["PrimaryGroupID 497", "UserShell /usr/bin/false", "NFSHomeDirectory /var/empty", "IsHidden 1", "Password *"] {
        #expect(log.contains("dscl . -create /Users/_viamprovisioner \(line)"), "user lacks \(line) in \(log)")
    }
    #expect(log.contains("chown -R 497:497 \(sandbox.serverDirectory.path)"), "directory not owned to 497: \(log)")
}

@Test func createTakesTheLowestIDOfTheRangeWhenItIsTheOnlyOneFree() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("users", (402...499).map { "u\($0) \($0)" }.joined(separator: "\n") + "\n")

    #expect(try sandbox.create() == 0)
    #expect(sandbox.log.contains("dscl . -create /Users/_viamprovisioner UniqueID 401"), "401 not taken: \(sandbox.log)")
}

@Test func createReusesAnExistingAccountAndMakesTheMissingDirectory() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("read", "UniqueID: 263\n")

    #expect(try sandbox.create() == 0)

    #expect(!sandbox.log.contains { $0.contains("-create") }, "created a second account: \(sandbox.log)")
    for directory in [sandbox.serverDirectory, sandbox.serverDirectory.appending(path: "data"), sandbox.serverDirectory.appending(path: "files")] {
        #expect(try sandbox.permissions(directory) == 0o700, "\(directory.lastPathComponent) isn't private")
    }
    #expect(sandbox.log.contains("chown -R 263:263 \(sandbox.serverDirectory.path)"), "directory not owned to 263: \(sandbox.log)")
}

@Test func createFailsWhenNoIDIsFree() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("users", (401...499).map { "u\($0) \($0)" }.joined(separator: "\n") + "\n")

    #expect(try sandbox.create() != 0)
    #expect(sandbox.errors.contains("No ID between 401 and 499 is free for _viamprovisioner."), "failed for another reason: \(sandbox.errors)")
    #expect(!sandbox.log.contains { $0.contains("-create") }, "created an account with no free ID: \(sandbox.log)")
}

@Test func removeDeletesDirectoryAndBothRecords() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("read", "UniqueID: 263\n")
    try FileManager.default.createDirectory(at: sandbox.serverDirectory.appending(path: "data"), withIntermediateDirectories: true)

    #expect(try sandbox.remove() == 0)

    #expect(!FileManager.default.fileExists(atPath: sandbox.serverDirectory.path), "server directory remains")
    #expect(sandbox.log.contains("dscl . -delete /Users/_viamprovisioner"), "user not deleted: \(sandbox.log)")
    #expect(sandbox.log.contains("dscl . -delete /Groups/_viamprovisioner"), "group not deleted: \(sandbox.log)")
}

@Test func removeWithTheAccountGoneStillRemovesTheDirectory() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try FileManager.default.createDirectory(at: sandbox.serverDirectory, withIntermediateDirectories: true)

    #expect(try sandbox.remove() == 0)

    #expect(!FileManager.default.fileExists(atPath: sandbox.serverDirectory.path), "server directory remains")
    #expect(!sandbox.log.contains { $0.contains("-delete") }, "deleted a record that wasn't there: \(sandbox.log)")
}

@Test func dataIsNotServedWithTheFiles() {
    #expect(!ServerAccount.dataDirectory.path.hasPrefix(ServerAccount.filesDirectory.path + "/"))
}

@Test func setUpMeansTheDirectoryBelongsToTheAccount() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let directory = sandbox.serverDirectory
    // A temporary directory belongs to the user running the tests, who stands in for the account.
    #expect(!ServerAccount.isSetUp(directory: directory, ownerName: NSUserName()), "set up with no directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(ServerAccount.isSetUp(directory: directory, ownerName: NSUserName()), "not set up though the directory is the account's")
    #expect(!ServerAccount.isSetUp(directory: directory, ownerName: ServerAccount.name), "set up though another user owns it")
}

@Test func setUpThoughTheSubdirectoriesCantBeSeen() throws {
    // The app runs as an operator, who can't see inside the account's private directory.
    let sandbox = try Sandbox()
    let directory = sandbox.serverDirectory
    try FileManager.default.createDirectory(at: directory.appending(path: "data"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        sandbox.cleanUp()
    }
    #expect(ServerAccount.isSetUp(directory: directory, ownerName: NSUserName()))
}

/// A tree under a temporary base: `apps/<mode>/Viam Provisioner.app/Contents/MacOS/provisioner-server`.
private func appTree(folderMode: Int, binaryMode: Int = 0o755) throws -> (base: URL, binary: URL, folder: URL) {
    let base = FileManager.default.temporaryDirectory.appending(path: "reach-\(UUID().uuidString)")
    let folder = base.appending(path: "apps")
    let macOS = folder.appending(path: "Viam Provisioner.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let binary = macOS.appending(path: "provisioner-server")
    try Data().write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: binaryMode], ofItemAtPath: binary.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
    try FileManager.default.setAttributes([.posixPermissions: folderMode], ofItemAtPath: folder.path)
    return (base, binary, folder)
}

@Test func serverReachesAnAppEveryoneCanOpen() throws {
    let tree = try appTree(folderMode: 0o755)
    defer { try? FileManager.default.removeItem(at: tree.base) }
    #expect(ServerAccount.unreachablePath(to: tree.binary, below: tree.base) == nil)
}

@Test func serverCantReachAnAppInsideAPrivateFolder() throws {
    // A closed home folder can be listed by other accounts but not entered, so a build there can't start as
    // _viamprovisioner; readable without the search bit catches a check of the wrong bit.
    let tree = try appTree(folderMode: 0o744)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.folder.path)
        try? FileManager.default.removeItem(at: tree.base)
    }
    #expect(ServerAccount.unreachablePath(to: tree.binary, below: tree.base)?.path == tree.folder.path)
}

@Test func serverCantRunABinaryOnlyItsOwnerMayExecute() throws {
    let tree = try appTree(folderMode: 0o755, binaryMode: 0o744)
    defer { try? FileManager.default.removeItem(at: tree.base) }
    #expect(ServerAccount.unreachablePath(to: tree.binary, below: tree.base)?.path == tree.binary.path)
}

@Test func conflictNamesEveryOtherUserAndGroupHoldingTheAccountsID() {
    let users = "root 0\n_viamprovisioner 499\n_newdaemon 499\nfoo 498\n"
    let groups = "_viamprovisioner 499\n_newgroup 499\nwheel 0\n"
    #expect(ServerAccount.conflict(users: users, groups: groups)
        == ServerAccount.IDConflict(id: 499, users: ["_newdaemon"], groups: ["_newgroup"]))
}

@Test func noConflictWhenTheIDIsTheAccountsAlone() {
    #expect(ServerAccount.conflict(users: "_viamprovisioner 499\nfoo 498\n", groups: "_viamprovisioner 499\n") == nil)
}

@Test func noConflictWithoutTheAccount() {
    #expect(ServerAccount.conflict(users: "foo 499\nbar 499\n", groups: "") == nil)
}

@Test func conflictMessageNamesTheIDAndTheAccounts() {
    let conflict = ServerAccount.IDConflict(id: 499, users: ["_newdaemon"], groups: ["_newgroup"])
    #expect(conflict.message == "Another account shares _viamprovisioner's ID 499: user _newdaemon, group _newgroup. It can read and change the server's data.")
}
