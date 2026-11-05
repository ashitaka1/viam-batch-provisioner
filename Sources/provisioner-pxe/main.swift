import Dispatch
import Foundation
import NIOCore
import ProvisionerPXE

let usage = """
    usage: provisioner-pxe --interface <name> --root <dir> [--boot-file grubx64.efi]
                           [--dhcp-port 67] [--pxe-port 4011] [--tftp-port 69] [--offer-to <ip>:<port>]
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\(usage)\n".utf8))
    exit(2)
}

func parseArguments() -> PXEConfiguration {
    var values: [String: String] = [:]
    var arguments = CommandLine.arguments.dropFirst()
    while let flag = arguments.popFirst() {
        guard flag.hasPrefix("--"), let value = arguments.popFirst() else { fail("bad argument: \(flag)") }
        values[String(flag.dropFirst(2))] = value
    }

    guard let interface = values.removeValue(forKey: "interface") else { fail("missing --interface") }
    guard let root = values.removeValue(forKey: "root") else { fail("missing --root") }
    var configuration = PXEConfiguration(interface: interface, tftpRoot: URL(fileURLWithPath: root))
    if let bootFile = values.removeValue(forKey: "boot-file") {
        configuration.bootFilename = bootFile
    }
    for (key, path) in [("dhcp-port", \PXEConfiguration.dhcpPort), ("pxe-port", \.pxePort), ("tftp-port", \.tftpPort)] {
        guard let value = values.removeValue(forKey: key) else { continue }
        guard let port = Int(value), (0...65535).contains(port) else { fail("bad --\(key): \(value)") }
        configuration[keyPath: path] = port
    }
    if let offerTo = values.removeValue(forKey: "offer-to") {
        let parts = offerTo.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]),
              let address = try? SocketAddress(ipAddress: String(parts[0]), port: port)
        else { fail("bad --offer-to: \(offerTo)") }
        configuration.offerDestination = address
    }
    if let unknown = values.keys.first {
        fail("unknown option --\(unknown)")
    }
    return configuration
}

let configuration = parseArguments()
let server = PXEServer(configuration: configuration)
do {
    try await server.start()
} catch {
    FileHandle.standardError.write(Data("provisioner-pxe: \(error)\n".utf8))
    exit(1)
}
let ports = server.boundPorts!
print("listening on \(configuration.interface): dhcp \(ports.dhcp) pxe \(ports.pxe) tftp \(ports.tftp)")

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Task {
        await server.stop()
    }
}
interrupt.resume()

for await event in server.events {
    switch event {
    case let .offered(client):
        let uuid = client.uuid.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"
        print("pxe \(client.mac) arch \(client.architecture) uuid \(uuid)")
    case let .fileSent(delivery):
        print("tftp \(delivery.filename) to \(delivery.clientAddress) mac \(delivery.mac.map(String.init(describing:)) ?? "-") \(delivery.bytes) bytes")
    }
}
