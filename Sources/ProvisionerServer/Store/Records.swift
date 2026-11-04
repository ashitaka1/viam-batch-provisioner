import Foundation

struct QueueRecord: Codable, Equatable, Sendable {
    /// The name as the client gave it; `key` is the lookup form.
    var name: String
    var addedAt: Date

    var key: String { name.lowercased() }
}

struct MachineRecord: Codable, Equatable, Sendable {
    var attempt: Int = 0
    var stage: String?
    var attemptStartedAt: Date?
    var progressAt: Date?
    var completedAt: Date?
    var failedAt: Date?
    var failureReason: String?
    var failureSource: String?
}

enum StoreError: Error, Equatable {
    case queueUnreadable(String)
    case io(String)
}

enum StoreCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
