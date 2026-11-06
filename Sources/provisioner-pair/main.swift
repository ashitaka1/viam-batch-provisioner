import AppKit
import Foundation
import ProvisionerKit
import ProvisionerPairHost
import SystemConfiguration

let usage = """
    usage: provisioner-pair [--org-id <id>]

    Signs the Viam Provisioner app in to one Viam organization: creates an API key
    for the app with your viam CLI login and hands it to the app after you confirm
    the code the app shows.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

// MARK: Arguments

var arguments = CommandLine.arguments.dropFirst()
var requestedOrgID: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--org-id": requestedOrgID = arguments.popFirst() ?? { fail(usage) }()
    case "--qr": fail("QR pairing ships with the iOS app.")
    case "-h", "--help": print(usage); exit(0)
    default: fail(usage)
    }
}

// MARK: Pick the org

guard let executable = await ViamCLI.locate() else { fail(pairingCLIMessage(ViamCLIError.notInstalled)) }
let cli = ViamCLI(run: ViamCLI.processRunner(executable: executable))
let orgs: [(id: String, name: String)]
do { orgs = try await cli.organizations() } catch { fail(pairingCLIMessage(error)) }

let org: (id: String, name: String)
if let requestedOrgID {
    guard let match = orgs.first(where: { $0.id == requestedOrgID }) else {
        fail("No organization with ID \(requestedOrgID) for this viam login.")
    }
    org = match
} else if orgs.count == 1 {
    org = orgs[0]
} else {
    for (index, candidate) in orgs.enumerated() { print("  \(index + 1). \(candidate.name)") }
    print("Organization [1-\(orgs.count)]: ", terminator: "")
    guard let line = readLine(), let choice = Int(line.trimmingCharacters(in: .whitespaces)),
          orgs.indices.contains(choice - 1) else { fail("Cancelled. No key was created.") }
    org = orgs[choice - 1]
}

// MARK: Pair

/// Everything the main flow waits on: host events and the operator's answers.
enum Input: Sendable {
    case event(PairingHost.Event)
    case line(String?)
}

let (inputs, input) = AsyncStream<Input>.makeStream()
let host = PairingHost(orgID: org.id, orgName: org.name)
let server: PairingHTTPServer
do { server = try await PairingHTTPServer.start(host: host) } catch { fail("Couldn't start the pairing listener: \(error)") }
Task {
    for await event in host.events { input.yield(.event(event)) }
}

func finish(_ message: String, status: Int32) async -> Never {
    await server.stop()
    if status == 0 { print(message) } else { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
    exit(status)
}

let link = PairingLink(host: "127.0.0.1", port: server.port, nonce: host.nonce)
guard await MainActor.run(body: { NSWorkspace.shared.open(link.url) }) else {
    await host.cancel()
    await finish("Couldn't open the Viam Provisioner app. Build and register it with 'just app', then try again.", status: 1)
}
print("Waiting for the app…")

/// The rest of the session, from the app connecting to the app's result.
func converse() async -> Never {
    var pending = inputs.makeAsyncIterator()
    var code: String?
    while code == nil {
        switch await pending.next() {
        case .event(.connected(let shown)): code = shown
        case .event(.cancelledByApp): await finish("Cancelled in the app. No key was created.", status: 0)
        case .event(.timedOut), nil: await finish("Timed out. No key was created.", status: 1)
        case .event(.result), .line: continue
        }
    }

    print("Pairing with \(org.name).")
    let shownCode = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        ? "\u{1B}[1;36m\(code!)\u{1B}[0m" : code!
    print("Does the app show \(shownCode)? [y/N] ", terminator: "")
    fflush(stdout)
    Thread.detachNewThread { input.yield(.line(readLine())) }

    var confirmed = false
    while !confirmed {
        switch await pending.next() {
        case .line(let answer):
            guard answer?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
                await host.cancel()
                await finish("Cancelled. No key was created.", status: 0)
            }
            confirmed = true
        case .event(.cancelledByApp): print(); await finish("Cancelled in the app. No key was created.", status: 0)
        case .event(.timedOut), nil: print(); await finish("Timed out. No key was created.", status: 1)
        case .event: continue
        }
    }

    let keyName: String = {
        let shortHost = SCDynamicStoreCopyLocalHostName(nil).map { $0 as String } ?? "mac"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "provisioner-app \(shortHost) \(formatter.string(from: Date()))"
    }()

    let end = await KeyHandoff(host: host, cli: cli, orgID: org.id, orgName: org.name, keyName: keyName).run {
        while true {
            switch await pending.next() {
            case .event(let event): return event
            case .line: continue
            case nil: return nil
            }
        }
    }
    await finish(end.message, status: end.succeeded ? 0 : 1)
}

await converse()
