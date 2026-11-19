import Foundation
import Logging

/// The server's diagnostic log: one swift-log interface to write, and `LogReader` to read it back.
/// macOS backs it with the unified log; Linux with stderr, which systemd's journal records.
public enum ProvisionerLog {
    /// The unified-log subsystem the server writes under.
    public static let subsystem = "com.bringingfire.viam-provisioner"
    /// The journal's `SYSLOG_IDENTIFIER` for the server on Linux: its executable's name.
    public static let journalIdentifier = "provisioner-server"

    /// Routes every `Logger` in the process to the platform's log. Each logger's label is its category.
    /// On macOS the lines also go to stderr when stderr is a terminal, so `swift run` shows them.
    public static func bootstrap() {
        #if canImport(OSLog)
        let terminal = isatty(STDERR_FILENO) != 0
        LoggingSystem.bootstrap { label in
            let unified = UnifiedLogHandler(subsystem: subsystem, category: label)
            return terminal ? MultiplexLogHandler([unified, StreamLogHandler.standardError(label: label)]) : unified
        }
        #else
        let journal = stderrIsJournal(ProcessInfo.processInfo.environment["JOURNAL_STREAM"])
        LoggingSystem.bootstrap { label in
            journal ? JournalLogHandler(category: label) as any LogHandler : StreamLogHandler.standardError(label: label)
        }
        #endif
    }

    /// The platform's reader of the server's log.
    public static func reader() -> any LogReader {
        #if canImport(OSLog)
        UnifiedLogReader(subsystem: subsystem)
        #else
        JournalReader(identifier: journalIdentifier)
        #endif
    }
}

#if !canImport(OSLog)
/// systemd sets `JOURNAL_STREAM` to the journal stream's `device:inode`, and a child inherits it even when
/// its stderr goes elsewhere, so stderr is the journal only when they match (systemd.exec(5)).
private func stderrIsJournal(_ value: String?) -> Bool {
    guard let parts = value?.split(separator: ":"), parts.count == 2,
          let device = UInt64(parts[0]), let inode = UInt64(parts[1]) else { return false }
    var info = stat()
    guard fstat(STDERR_FILENO, &info) == 0 else { return false }
    return UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode
}
#endif

/// One line of the log, as a reader returns it.
public struct LogLine: Sendable, Equatable {
    public var date: Date
    public var level: Logger.Level
    public var category: String
    public var message: String
    public var processID: Int32

    public init(date: Date, level: Logger.Level, category: String, message: String, processID: Int32) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.processID = processID
    }
}

public protocol LogReader: Sendable {
    /// The lines written since `date`, oldest first.
    func history(since date: Date) async throws -> [LogLine]
    /// The lines written from now on, until the caller stops iterating.
    func follow() -> AsyncThrowingStream<LogLine, any Error>
}

/// The lines that mark the server's launches and stops, which the app reads to explain a server that
/// isn't running.
public enum ServerLifecycle {
    public static let category = "lifecycle"
    public static let launched = "launched"
    /// Begins the critical line the server logs with the error that stopped it.
    public static let stoppedPrefix = "stopped: "

    /// The error that stopped the latest launch in `lines`, or nil when the latest launch hasn't stopped
    /// with one. Only a stop from the launch's own process counts, so another server run by hand doesn't
    /// stand in for the daemon's.
    public static func startupError(in lines: [LogLine]) -> String? {
        var error: String?
        var launch: Int32?
        for line in lines where line.category == category {
            if line.message == launched {
                launch = line.processID
                error = nil
            } else if line.message.hasPrefix(stoppedPrefix), launch == nil || launch == line.processID {
                error = String(line.message.dropFirst(stoppedPrefix.count))
            }
        }
        return error
    }
}

/// Renders a message and its metadata as one line of text.
func render(_ message: Logger.Message, _ metadata: Logger.Metadata) -> String {
    guard !metadata.isEmpty else { return message.description }
    let pairs = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    return ([message.description] + pairs).joined(separator: " ")
}

/// Splits a process's output, which arrives in arbitrary chunks, into lines.
struct LineSplitter {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// The unterminated last line, if any.
    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// Runs a reader's command and yields its parsed output lines until the caller stops iterating, then
/// terminates it.
func followProcess(_ executable: String, _ arguments: [String],
                   parse: @escaping @Sendable (String) -> LogLine?) -> AsyncThrowingStream<LogLine, any Error> {
    AsyncThrowingStream { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let splitter = LockedSplitter()
        // The stream ends at the pipe's end of file, after the last lines, not when the process exits.
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard chunk.isEmpty else {
                for line in splitter.append(chunk) {
                    if let parsed = parse(line) { continuation.yield(parsed) }
                }
                return
            }
            handle.readabilityHandler = nil
            if let last = splitter.finish(), let parsed = parse(last) { continuation.yield(parsed) }
            process.waitUntilExit()
            continuation.finish(throwing: process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal
                                ? nil : ReaderError.exited(executable, process.terminationStatus))
        }
        continuation.onTermination = { _ in
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

/// Runs a reader's command to completion and returns its output lines.
func runProcess(_ executable: String, _ arguments: [String]) async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return continuation.resume(throwing: error)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return continuation.resume(throwing: ReaderError.exited(executable, process.terminationStatus))
            }
            var splitter = LineSplitter()
            continuation.resume(returning: splitter.append(data) + [splitter.finish()].compactMap { $0 })
        }
    }
}

public enum ReaderError: Error, CustomStringConvertible {
    case exited(String, Int32)

    public var description: String {
        switch self {
        case .exited(let executable, let status): "\(executable) exited with status \(status)"
        }
    }
}

private final class LockedSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return splitter.append(chunk)
    }

    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return splitter.finish()
    }
}
