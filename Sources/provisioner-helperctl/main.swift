import Dispatch
import Foundation
import ProvisionerHelperXPC

// Drives ProvisionerHelper over XPC in place of ProvisionerServer, for development and hardware runs.

let usage = """
    usage: provisioner-helperctl serve <interface> [<boot-file>]   serve, then print events until interrupted
           provisioner-helperctl watch                             print events until interrupted
           provisioner-helperctl status                            print the interface being served
           provisioner-helperctl stop
           provisioner-helperctl push <dir>                        copy every file under <dir> into the TFTP root
           provisioner-helperctl write <path> <file>
           provisioner-helperctl remove <path>
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("provisioner-helperctl: \(message)\n".utf8))
    exit(code)
}

func printEvents(_ client: HelperClient) async {
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { client.invalidate() }
    interrupt.resume()
    for await event in client.events {
        switch event {
        case let .offered(mac, architecture, uuid):
            print("offered \(mac) arch \(architecture) uuid \(uuid ?? "-")")
        case let .fileSent(filename, clientAddress, mac, bytes):
            print("sent \(filename) to \(clientAddress) mac \(mac ?? "-") \(bytes) bytes")
        }
    }
}

/// Every regular file under `directory`, as paths relative to it, following symlinks.
func files(under directory: URL) -> [String] {
    let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard let walker = FileManager.default.enumerator(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey])
    else { fail("cannot read \(directory.path)") }
    return walker.compactMap { item in
        guard let url = item as? URL,
              (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }.sorted()
}

let client = HelperClient()
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("serve", 2), ("serve", 3):
        try await client.serve(interface: arguments[1], bootFilename: arguments.count == 3 ? arguments[2] : "grubx64.efi")
        print("serving on \(arguments[1])")
        await printEvents(client)
    case ("watch", 1):
        print("serving on \(try await client.servingInterface() ?? "nothing")")
        await printEvents(client)
    case ("status", 1):
        print(try await client.servingInterface() ?? "not serving")
    case ("stop", 1):
        try await client.stopServing()
    case ("push", 2):
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        for path in files(under: directory) {
            let contents = try Data(contentsOf: directory.appendingPathComponent(path))
            try await client.writeFile(path, contents: contents)
            print("wrote \(path) (\(contents.count) bytes)")
        }
    case ("write", 3):
        try await client.writeFile(arguments[1], contents: try Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    case ("remove", 2):
        try await client.removeFile(arguments[1])
    default:
        fail("bad arguments\n\(usage)", code: 2)
    }
} catch {
    fail("\(error)")
}
