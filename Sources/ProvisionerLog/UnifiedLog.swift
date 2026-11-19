#if canImport(OSLog)
import Foundation
import Logging
import OSLog

/// Writes swift-log events to the unified log. Info persists as Default, because the unified log keeps
/// Info lines only in memory and `log show` leaves them out.
public struct UnifiedLogHandler: LogHandler {
    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level = .info
    private let logger: os.Logger

    public init(subsystem: String, category: String) {
        logger = os.Logger(subsystem: subsystem, category: category)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let merged = event.metadata.map { metadata.merging($0) { $1 } } ?? metadata
        let text = render(event.message, merged)
        // The server logs nothing secret, so every line is public; the unified log would otherwise
        // redact each interpolated value as <private>.
        logger.log(level: UnifiedLogFormat.osLogType(for: event.level), "\(text, privacy: .public)")
    }
}

/// Reads the unified log as the logged-in user, which works for an administrator: history through
/// `OSLogStore`, new lines through `log stream`, since `OSLogStore` can't follow.
public struct UnifiedLogReader: LogReader {
    public let subsystem: String

    public init(subsystem: String) { self.subsystem = subsystem }

    public func history(since date: Date) async throws -> [LogLine] {
        let store = try OSLogStore.local()
        let entries = try store.getEntries(at: store.position(date: date),
                                           matching: NSPredicate(format: "subsystem == %@", subsystem))
        return entries.compactMap { entry in
            guard let entry = entry as? OSLogEntryLog, entry.date >= date else { return nil }
            return LogLine(date: entry.date, level: UnifiedLogFormat.level(entry.level), category: entry.category,
                           message: entry.composedMessage, processID: entry.processIdentifier)
        }
    }

    public func follow() -> AsyncThrowingStream<LogLine, any Error> {
        followProcess("/usr/bin/log", ["stream", "--style", "ndjson", "--level", "info",
                                       "--predicate", "subsystem == \"\(subsystem)\""],
                      parse: UnifiedLogFormat.line(fromNDJSON:))
    }
}

enum UnifiedLogFormat {
    static func osLogType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: .debug
        case .info, .notice: .default
        case .warning, .error: .error
        case .critical: .fault
        }
    }

    static func level(_ level: OSLogEntryLog.Level) -> Logging.Logger.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .error: .error
        case .fault: .critical
        default: .notice
        }
    }

    /// `log stream`'s `messageType` for a line written at `level`.
    static func messageType(for level: Logging.Logger.Level) -> String {
        switch osLogType(for: level) {
        case .debug: "Debug"
        case .info: "Info"
        case .error: "Error"
        case .fault: "Fault"
        default: "Default"
        }
    }

    static func level(messageType: String) -> Logging.Logger.Level {
        switch messageType {
        case "Debug": .debug
        case "Info": .info
        case "Error": .error
        case "Fault": .critical
        default: .notice
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    private struct Event: Decodable {
        let messageType: String
        let category: String
        let timestamp: String
        let eventMessage: String
        let processID: Int32
    }

    /// One line of `log stream --style ndjson`; nil for its banner and anything else that isn't an event.
    static func line(fromNDJSON text: String) -> LogLine? {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8)),
              let date = timestamp.date(from: event.timestamp) else { return nil }
        return LogLine(date: date, level: level(messageType: event.messageType), category: event.category,
                       message: event.eventMessage, processID: event.processID)
    }
}
#endif
