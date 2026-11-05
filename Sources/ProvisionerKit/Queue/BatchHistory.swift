public import Foundation
public import Observation

/// One provisioning run, as the history shows it.
public struct BatchRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var environmentName: String
    public var mode: ProvisionMode
    public var orgName: String?
    public var locationName: String?
    public var serverName: String
    public var serverURL: URL
    /// The names the server queued.
    public var machines: [String]
    /// One sentence per machine that wasn't queued.
    public var problems: [String]

    public init(id: UUID, date: Date, environmentName: String, mode: ProvisionMode, orgName: String?, locationName: String?,
                serverName: String, serverURL: URL, machines: [String], problems: [String]) {
        self.id = id
        self.date = date
        self.environmentName = environmentName
        self.mode = mode
        self.orgName = orgName
        self.locationName = locationName
        self.serverName = serverName
        self.serverURL = serverURL
        self.machines = machines
        self.problems = problems
    }

    public init(id: UUID = UUID(), environment: Environment, outcome: BatchOutcome, server: DiscoveredServer, date: Date) {
        self.init(id: id, date: date, environmentName: environment.name, mode: environment.provisionMode,
                  orgName: environment.provisionMode == .full ? environment.orgName : nil,
                  locationName: environment.provisionMode == .full ? environment.locationName : nil,
                  serverName: server.name, serverURL: server.baseURL, machines: outcome.queued, problems: outcome.problems)
    }
}

/// The batches provisioned from this Mac, newest first, in one JSON file written atomically.
@MainActor @Observable
public final class BatchHistory {
    public static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "Viam Provisioner/batches.json")
    }

    public private(set) var records: [BatchRecord] = []
    /// Why the file couldn't be read. Saving is refused until it can, so the file is never replaced.
    public private(set) var loadError: String?

    private let file: URL

    public init(file: URL = BatchHistory.defaultFile) {
        self.file = file
    }

    public func load() {
        do {
            records = try read()
            loadError = nil
        } catch {
            records = []
            loadError = "Couldn't read the batch history in \(file.path): \(error.localizedDescription)"
        }
    }

    /// Adds the record, or replaces the one with its ID.
    public func save(_ record: BatchRecord) throws {
        var all = try read()
        all.removeAll { $0.id == record.id }
        all.append(record)
        all.sort { $0.date > $1.date }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
        records = all
        loadError = nil
    }

    private func read() throws -> [BatchRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BatchRecord].self, from: Data(contentsOf: file)).sorted { $0.date > $1.date }
    }
}
