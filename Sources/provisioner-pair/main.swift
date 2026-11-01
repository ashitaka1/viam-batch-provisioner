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

func cliMessage(_ error: any Error) -> String {
    switch error as? ViamCLIError {
    case .notInstalled: "Install the viam CLI: https://docs.viam.com/cli/"
    case .notLoggedIn: "Run 'viam login' first."
    case .failed(let stderr): "The viam CLI failed: \(stderr)"
    case .unparsableOrganizations: "Couldn't read the viam CLI's organization list. Update it with 'viam update'."
    case .unparsableKey, nil: "The viam CLI failed: \(error)"
    }
}

func deleteHint(_ keyName: String) -> String {
    "Delete it in Viam: Organization → API keys → \"\(keyName)\"."
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

let cli = ViamCLI()
let orgs: [(id: String, name: String)]
do { orgs = try await cli.organizations() } catch { fail(cliMessage(error)) }

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
    print("Does the app show \(code!)? [y/N] ", terminator: "")
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

    let key: (id: String, key: String)
    do {
        key = try await cli.createKey(orgID: org.id, name: keyName)
    } catch ViamCLIError.unparsableKey {
        await host.cancel()
        await finish("The viam CLI created a key but its output couldn't be read. \(deleteHint(keyName))", status: 1)
    } catch {
        await host.cancel()
        await finish(cliMessage(error), status: 1)
    }

    do {
        try await host.release(PairingPayload(orgID: org.id, orgName: org.name, keyID: key.id, key: key.key, keyName: keyName))
    } catch {
        await finish("The pairing ended before the key was sent. \(deleteHint(keyName))", status: 1)
    }

    while true {
        switch await pending.next() {
        case .event(.result(.stored, _)): await finish("Signed in to \(org.name).", status: 0)
        case .event(.result(.rejected, let message)):
            await finish("The app couldn't use key \"\(keyName)\": \(message ?? "rejected"). \(deleteHint(keyName))", status: 1)
        case .event(.cancelledByApp): await finish("Cancelled in the app after the key was created. \(deleteHint(keyName))", status: 1)
        case .event(.timedOut), nil:
            await finish("""
                Timed out waiting for the app after creating key "\(keyName)". If the app's Settings → Organizations \
                doesn't list \(org.name), \(deleteHint(keyName).prefix(1).lowercased() + deleteHint(keyName).dropFirst())
                """, status: 1)
        case .event, .line: continue
        }
    }
}

await converse()
