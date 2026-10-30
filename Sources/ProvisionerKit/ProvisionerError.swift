package import ProvisionerAPI

public enum ProvisionerError: Error, Sendable {
    public struct Detail: Sendable, Equatable {
        public var index: Int?
        public var field: String?
        public var message: String
    }

    case invalidCredentials
    /// The server answered with a documented error body.
    case server(status: Int, code: String, message: String, details: [Detail])
    /// The server answered with a status or body the spec doesn't describe.
    case unexpectedResponse(status: Int)
    case transport(any Error)

    package init(status: Int, _ body: Components.Schemas._Error) {
        self = .server(
            status: status, code: body.error.code.rawValue, message: body.error.message,
            details: (body.error.details ?? []).map { Detail(index: $0.index, field: $0.field, message: $0.message) })
    }
}

extension ProvisionerError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.invalidCredentials, .invalidCredentials):
            true
        case let (.server(s1, c1, m1, d1), .server(s2, c2, m2, d2)):
            s1 == s2 && c1 == c2 && m1 == m2 && d1 == d2
        case let (.unexpectedResponse(s1), .unexpectedResponse(s2)):
            s1 == s2
        case let (.transport(e1), .transport(e2)):
            String(describing: e1) == String(describing: e2)
        default:
            false
        }
    }
}
