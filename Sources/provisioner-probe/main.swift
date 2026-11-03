import Foundation
import ProvisionerKit
import ViamAPI

let usage = """
    usage: provisioner-probe browse
           provisioner-probe check <base-url>
           provisioner-probe watch <base-url>
           provisioner-probe notify <base-url>
           provisioner-probe viam-org <org-id>    (VIAM_API_KEY_ID and VIAM_API_KEY in the environment)
           provisioner-probe viam-locations <org-id>
           provisioner-probe viam-batch <org-id> <location-id> <prefix> <count>
           provisioner-probe viam-delete-key <org-id> <key-id>
             (the viam-* commands use VIAM_API_KEY_ID and VIAM_API_KEY when set,
              otherwise the org's key paired into the app's Keychain)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func client(_ arguments: ArraySlice<String>) -> ProvisionerClient {
    guard let string = arguments.first, let url = URL(string: string), url.host != nil else { fail(usage) }
    return ProvisionerClient(baseURL: url)
}

/// Lists Bonjour-advertised servers for five seconds.
func browse() async {
    let browsing = Task {
        do {
            for try await servers in ServerBrowser().servers() {
                print("servers:", servers.map { "\($0.name) \($0.baseURL)" })
            }
        } catch {
            fail("browse failed: \(error)")
        }
    }
    try? await Task.sleep(for: .seconds(5))
    browsing.cancel()
}

/// Provisions a throwaway name, finds it in the queue, removes it, and checks it's gone.
func check(_ client: ProvisionerClient) async {
    do {
        let status = try await client.status()
        print("status: \(status.serverName) api \(status.apiVersion), last event \(status.lastEventID), services \(status.services)")

        let name = "probe-\(Int(Date().timeIntervalSince1970))"
        let environment = EnvironmentConfig(
            provisionMode: .osOnly, username: "viam", passwordHash: "$6$probe$probe",
            sshPublicKey: "ssh-ed25519 AAAAprobe probe", timezone: "UTC")
        let results = try await client.provision([ProvisionRequest(name: name, environment: environment)])
        print("provision:", results)
        guard results.count == 1, results[0].name == name, results[0].added else { fail("FAIL: \(name) not added") }

        let snapshot = try await client.queue()
        guard snapshot.entries.contains(where: { $0.name == name && $0.status == .queued }) else {
            fail("FAIL: \(name) not queued in snapshot")
        }
        print("queue: \(snapshot.entries.count) entries, last event \(snapshot.lastEventID)")

        try await client.remove(named: name)
        do {
            _ = try await client.entry(named: name)
            fail("FAIL: \(name) still present after remove")
        } catch .server(status: 404, _, _, _) {
            print("removed \(name)")
        }
        print("PASS")
    } catch {
        fail("FAIL: \(error)")
    }
}

/// Prints every update and connection state until interrupted.
func watch(_ client: ProvisionerClient) async {
    let feed = QueueFeed(source: client)
    Task {
        for await state in feed.states { print("state:", state) }
    }
    for await update in feed.updates() {
        switch update {
        case .snapshot(let entries):
            print("snapshot:", entries.map { "\($0.name)=\($0.status.rawValue)" })
        case .event(let event, let inSnapshot):
            print("event \(event.id) \(event.name) \(event.kind) inSnapshot=\(inSnapshot)")
        }
    }
}

/// Prints the notifications the app would post, until interrupted.
func notify(_ client: ProvisionerClient) async {
    struct PrintingPoster: NotificationPoster {
        func post(_ notification: InstallNotification) async throws {
            print("notification \(notification.identifier): \(notification.title)",
                  notification.subtitle.map { "| \($0)" } ?? "", "|", notification.body)
        }
    }
    await InstallNotifier(poster: PrintingPoster()).run(QueueFeed(source: client).updates())
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = CommandLine.arguments.dropFirst()
/// Reads one org from Viam with an API key, the call the app uses to validate keys.
func viamOrg(_ arguments: ArraySlice<String>) async {
    let environment = ProcessInfo.processInfo.environment
    guard let id = arguments.first, let keyID = environment["VIAM_API_KEY_ID"], let key = environment["VIAM_API_KEY"] else {
        fail(usage)
    }
    do {
        let org = try await ViamAppClient(keyID: keyID, key: key).organization(id: id)
        print("org \(org.id): \(org.name)")
    } catch {
        fail("viam-org failed: \(error)")
    }
}

/// An org key from the environment, or else the one paired into the app's Keychain.
func orgCredential(_ orgID: String) -> OrgCredential {
    let environment = ProcessInfo.processInfo.environment
    let keyID = environment["VIAM_API_KEY_ID"], key = environment["VIAM_API_KEY"]
    if keyID != nil || key != nil {
        guard let keyID, !keyID.isEmpty else { fail("VIAM_API_KEY is set but VIAM_API_KEY_ID is missing or empty") }
        guard let key, !key.isEmpty else { fail("VIAM_API_KEY_ID is set but VIAM_API_KEY is missing or empty") }
        return OrgCredential(
            PairingPayload(orgID: orgID, orgName: "", keyID: keyID, key: key, keyName: "environment"), addedAt: Date())
    }
    do {
        guard let credential = try KeychainOrgCredentialStore().all().first(where: { $0.orgID == orgID }) else {
            fail("no key for \(orgID): set VIAM_API_KEY_ID and VIAM_API_KEY, or run just pair-app")
        }
        return credential
    } catch {
        fail("couldn't read the app's key from the Keychain (\(error)); set VIAM_API_KEY_ID and VIAM_API_KEY instead")
    }
}

/// Deletes an org API key; the viam CLI can create keys but not delete them.
func viamDeleteKey(_ arguments: ArraySlice<String>) async {
    let arguments = Array(arguments)
    guard arguments.count == 2 else { fail(usage) }
    do {
        try await ViamKeyDeleter().deleteKey(id: arguments[1], using: orgCredential(arguments[0]))
        print("deleted key \(arguments[1])")
    } catch {
        fail("viam-delete-key failed: \(error)")
    }
}

func viamLocations(_ arguments: ArraySlice<String>) async {
    guard let orgID = arguments.first else { fail(usage) }
    do {
        for location in try await ViamOrgFleet(credential: orgCredential(orgID)).locations() {
            print("\(location.id) \(location.name)")
        }
    } catch {
        fail("viam-locations failed: \(error)")
    }
}

/// Creates machines with MachineBatch, checks each blob's part ID against Viam,
/// then deletes them. Never prints a secret.
func viamBatch(_ arguments: ArraySlice<String>) async {
    let arguments = Array(arguments)
    guard arguments.count == 4, let count = Int(arguments[3]) else { fail(usage) }
    let credential = orgCredential(arguments[0])
    let fleet = ViamOrgFleet(credential: credential)
    let result: BatchResult
    do {
        result = try await MachineBatch(fleet: fleet, location: arguments[1]).create(prefix: arguments[2], count: count, queued: [])
    } catch {
        switch error {
        case .naming(let naming): fail("viam-batch: \(naming.localizedDescription)")
        case .fleet(let fleet): fail("viam-batch: \(fleet)")
        }
    }

    var ok = result.failures.isEmpty && result.stop == nil
    for machine in result.created { print("created \(machine)") }
    for failure in result.failures {
        print("failed \(failure.name): \(failure.message)", failure.leftInViam ? "(may remain in Viam: \(failure.machineID ?? "ID unknown"))" : "")
    }
    if let stop = result.stop { print("stopped: \(stop); untried \(result.untried)") }

    let client = ViamAppClient(keyID: credential.keyID, key: credential.key)
    for machine in result.created {
        do {
            let blob = try JSONSerialization.jsonObject(with: machine.credentialsJSON) as? [String: [String: String]]
            let part = try await client.robotPart(id: machine.partID)
            if blob?["cloud"]?["id"] == part.id && blob?["cloud"]?["secret"] == part.secret {
                print("verified \(machine.name)")
            } else {
                print("MISMATCH \(machine.name): viam.json doesn't match part \(machine.partID)")
                ok = false
            }
        } catch {
            print("couldn't verify \(machine.name): \(error)")
            ok = false
        }
        do {
            try await fleet.deleteMachine(id: machine.machineID)
            print("deleted \(machine.name)")
        } catch {
            print("COULDN'T DELETE \(machine.name) (\(machine.machineID)): \(error)")
            ok = false
        }
    }
    if !ok { exit(1) }
    print("PASS")
}

switch arguments.popFirst() {
case "browse": await browse()
case "check": await check(client(arguments))
case "watch": await watch(client(arguments))
case "notify": await notify(client(arguments))
case "viam-org": await viamOrg(arguments)
case "viam-locations": await viamLocations(arguments)
case "viam-batch": await viamBatch(arguments)
case "viam-delete-key": await viamDeleteKey(arguments)
default: fail(usage)
}
