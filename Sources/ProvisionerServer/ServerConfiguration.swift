import Foundation

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
}

/// Where PXE is served: the interface, and the file proxy DHCP names as the boot file.
struct PXESettings: Sendable, Equatable, Decodable {
    var interface: String
    var bootFile = "grubx64.efi"

    init(interface: String, bootFile: String = "grubx64.efi") {
        self.interface = interface
        self.bootFile = bootFile
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case interface
        case bootFile = "boot_file"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys
        if let unknown = keys.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: [unknown], debugDescription: "unknown key \(unknown.stringValue)"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interface = try container.decode(String.self, forKey: .interface)
        bootFile = try container.decodeIfPresent(String.self, forKey: .bootFile) ?? "grubx64.efi"
    }
}

struct ServerConfiguration: Sendable {
    var port: Int
    var bind: String
    var files: URL
    var dataDirectory: URL
    var advertiseAddress: String?
    /// The PXE install image, relative to `files`.
    var bootImage: String?
    /// Where to serve PXE; nil serves none.
    var pxe: PXESettings?

    /// The directory TFTP serves.
    var tftpRoot: URL { dataDirectory.appending(path: "tftp") }

    static let usage = """
        usage: provisioner-server --files <dir> [--port <n>] [--bind <address>] [--data-dir <dir>] [--advertise-address <host:port>] [--boot-image <path under --files>] [--pxe-interface <name> [--boot-file <name>]]
        """

    /// The daemon's PXE settings, which first-run setup writes.
    static func settingsFile(in dataDirectory: URL) -> URL { dataDirectory.appending(path: "pxe.json") }

    /// This configuration, with `pxe` read from `pxe.json` when no flag set it.
    func readingPXESettingsFile() throws(ConfigurationError) -> ServerConfiguration {
        guard pxe == nil else { return self }
        var configuration = self
        configuration.pxe = try Self.loadPXESettings(dataDirectory: dataDirectory)
        return configuration
    }

    /// The settings in `pxe.json` under `dataDirectory`, or nil when there is no such file.
    static func loadPXESettings(dataDirectory: URL) throws(ConfigurationError) -> PXESettings? {
        let file = settingsFile(in: dataDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        } catch {
            throw ConfigurationError(description: "\(file.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(PXESettings.self, from: data)
        } catch {
            throw ConfigurationError(description: "\(file.path) is not valid PXE settings: \(error)")
        }
    }

    static var defaultDataDirectory: URL {
        #if os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_DATA_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")
        return base.appending(path: "viam-provisioner/server")
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Viam Provisioner/Server")
        #endif
    }

    static func parse(_ arguments: [String]) throws(ConfigurationError) -> ServerConfiguration {
        var values: [String: String] = [:]
        var rest = arguments[...]
        let known: Set = ["--port", "--bind", "--files", "--data-dir", "--advertise-address", "--boot-image",
                          "--pxe-interface", "--boot-file"]
        while let flag = rest.popFirst() {
            guard known.contains(flag) else { throw ConfigurationError(description: "unknown option \(flag)") }
            guard let value = rest.popFirst() else { throw ConfigurationError(description: "\(flag) needs a value") }
            values[flag] = value
        }
        guard let files = values["--files"] else { throw ConfigurationError(description: "--files is required") }
        var port = 8234
        if let text = values["--port"] {
            guard let value = Int(text), (0...65535).contains(value) else {
                throw ConfigurationError(description: "--port must be a port number, got \(text)")
            }
            port = value
        }
        if values["--boot-file"] != nil, values["--pxe-interface"] == nil {
            throw ConfigurationError(description: "--boot-file needs --pxe-interface")
        }
        let dataDirectory = values["--data-dir"].map { URL(filePath: $0) } ?? defaultDataDirectory
        let pxe = values["--pxe-interface"].map { PXESettings(interface: $0, bootFile: values["--boot-file"] ?? "grubx64.efi") }
        let configuration = ServerConfiguration(
            port: port,
            bind: values["--bind"] ?? "0.0.0.0",
            files: URL(filePath: files),
            dataDirectory: dataDirectory,
            advertiseAddress: values["--advertise-address"],
            bootImage: values["--boot-image"],
            pxe: pxe)
        if contains(configuration.files, configuration.dataDirectory) {
            throw ConfigurationError(description: "--data-dir must be outside --files, which is served to the network")
        }
        if let image = configuration.bootImage {
            let url = configuration.files.appending(path: image)
            guard !image.hasPrefix("/"), !image.split(separator: "/").contains("..") else {
                throw ConfigurationError(description: "--boot-image must be a path under --files, got \(image)")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ConfigurationError(description: "--boot-image \(image) is not a file under --files")
            }
        }
        return configuration
    }

    /// Whether `inner` is `outer` or lies under it, after resolving symlinks.
    private static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let outer = resolved(outer).pathComponents
        let inner = resolved(inner).pathComponents
        return inner.starts(with: outer)
    }

    /// `url` with symlinks resolved in its deepest existing ancestor; a data
    /// directory need not exist yet.
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return url.standardizedFileURL }
        defer { free(real) }
        return missing.reduce(URL(filePath: String(cString: real))) { $0.appending(path: $1) }
    }
}
