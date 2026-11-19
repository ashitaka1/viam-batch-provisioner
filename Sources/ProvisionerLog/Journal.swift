import Foundation
import Logging

/// Writes to stderr with a syslog priority prefix, which systemd's journal records as the line's
/// priority, and the category ahead of the message.
public struct JournalLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .info
    private let category: String

    public init(category: String) { self.category = category }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let merged = event.metadata.map { metadata.merging($0) { $1 } } ?? metadata
        let text = JournalFormat.render(level: event.level, category: category, message: render(event.message, merged))
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Reads the server's lines from systemd's journal through `journalctl`.
public struct JournalReader: LogReader {
    public let identifier: String

    public init(identifier: String) { self.identifier = identifier }

    public func history(since date: Date) async throws -> [LogLine] {
        try await runProcess("/usr/bin/env", ["journalctl", "--no-pager", "-o", "json", "-t", identifier,
                                              "--since", "@\(Int(date.timeIntervalSince1970))"])
            .compactMap(JournalFormat.line(fromJSON:))
            .filter { $0.date >= date }
    }

    public func follow() -> AsyncThrowingStream<LogLine, any Error> {
        followProcess("/usr/bin/env", ["journalctl", "--no-pager", "-o", "json", "-t", identifier, "-f", "-n", "0"],
                      parse: JournalFormat.line(fromJSON:))
    }
}

enum JournalFormat {
    /// Syslog priorities (RFC 5424 §6.2.1).
    static func priority(_ level: Logger.Level) -> Int {
        switch level {
        case .trace, .debug: 7
        case .info: 6
        case .notice: 5
        case .warning: 4
        case .error: 3
        case .critical: 2
        }
    }

    static func level(priority: Int) -> Logger.Level {
        switch priority {
        case ...2: .critical
        case 3: .error
        case 4: .warning
        case 5: .notice
        case 6: .info
        default: .debug
        }
    }

    /// The journal splits stderr into entries at each newline, so the message's own newlines become spaces.
    static func render(level: Logger.Level, category: String, message: String) -> String {
        let flat = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        return "<\(priority(level))>\(category): \(flat)\n"
    }

    private struct Entry: Decodable {
        let realtime: String
        let priority: String?
        let pid: String?
        let message: String

        enum CodingKeys: String, CodingKey {
            case realtime = "__REALTIME_TIMESTAMP", priority = "PRIORITY", pid = "_PID", message = "MESSAGE"
        }
    }

    /// One line of `journalctl -o json`; nil for an entry whose message isn't text.
    static func line(fromJSON text: String) -> LogLine? {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(text.utf8)),
              let microseconds = Double(entry.realtime) else { return nil }
        let parts = entry.message.split(separator: ":", maxSplits: 1)
        let (category, message) = parts.count == 2 && !parts[0].contains(" ")
            ? (String(parts[0]), String(parts[1].dropFirst()))
            : ("", entry.message)
        return LogLine(date: Date(timeIntervalSince1970: microseconds / 1_000_000),
                       level: level(priority: entry.priority.flatMap(Int.init) ?? 6),
                       category: category, message: message, processID: entry.pid.flatMap(Int32.init) ?? 0)
    }
}
