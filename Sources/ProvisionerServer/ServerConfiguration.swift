import Foundation

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
}

struct ServerConfiguration: Sendable {
    var port: Int
    var bind: String
    var files: URL
    var dataDirectory: URL
    var advertiseAddress: String?

    static let usage = """
        usage: provisioner-server --files <dir> [--port <n>] [--bind <address>] [--data-dir <dir>] [--advertise-address <host:port>]
        """

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
        let known: Set = ["--port", "--bind", "--files", "--data-dir", "--advertise-address"]
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
        let configuration = ServerConfiguration(
            port: port,
            bind: values["--bind"] ?? "0.0.0.0",
            files: URL(filePath: files),
            dataDirectory: values["--data-dir"].map { URL(filePath: $0) } ?? defaultDataDirectory,
            advertiseAddress: values["--advertise-address"])
        if contains(configuration.files, configuration.dataDirectory) {
            throw ConfigurationError(description: "--data-dir must be outside --files, which is served to the network")
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
