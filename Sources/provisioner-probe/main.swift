import Foundation
import ProvisionerKit

let usage = """
    usage: provisioner-probe browse
           provisioner-probe check <base-url>
           provisioner-probe watch <base-url>
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

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = CommandLine.arguments.dropFirst()
switch arguments.popFirst() {
case "browse": await browse()
case "check": await check(client(arguments))
case "watch": await watch(client(arguments))
default: fail(usage)
}
