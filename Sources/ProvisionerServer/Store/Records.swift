import Foundation

struct QueueRecord: Codable, Equatable, Sendable {
    /// The name as the client gave it; `key` is the lookup form.
    var name: String
    var addedAt: Date
    var osName: String?
    var provisionMode: String?
    /// Whether the request carried a Tailscale key; the key itself is never recorded.
    var joinsTailscale: Bool?

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
    var steps: [StepRecord] = []
    var bootFilesSent: [String] = []
    var downloadBytes: Int?
    var downloadTotal: Int?
    var failureStep: String?
}

struct StepRecord: Codable, Equatable, Sendable {
    var step: String
    var at: Date
    var attempt: Int
}

extension MachineRecord {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        attemptStartedAt = try c.decodeIfPresent(Date.self, forKey: .attemptStartedAt)
        progressAt = try c.decodeIfPresent(Date.self, forKey: .progressAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        failedAt = try c.decodeIfPresent(Date.self, forKey: .failedAt)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        failureSource = try c.decodeIfPresent(String.self, forKey: .failureSource)
        steps = try c.decodeIfPresent([StepRecord].self, forKey: .steps) ?? []
        bootFilesSent = try c.decodeIfPresent([String].self, forKey: .bootFilesSent) ?? []
        downloadBytes = try c.decodeIfPresent(Int.self, forKey: .downloadBytes)
        downloadTotal = try c.decodeIfPresent(Int.self, forKey: .downloadTotal)
        failureStep = try c.decodeIfPresent(String.self, forKey: .failureStep)
    }
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
