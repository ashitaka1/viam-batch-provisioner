import Foundation

public enum HelperError: Error, Hashable, Sendable {
    /// The path is absolute, empty, or has an empty, `.` or `..` component.
    case invalidPath(String)
    case serveFailed(String)
    case writeFailed(String)
    /// The XPC connection failed: the helper isn't registered or approved, or refused this process.
    case connection(String)
    /// The client was invalidated; it makes no more calls.
    case invalidated

    public static let domain = "com.bringingfire.viam-provisioner.helper"
    private static let detailKey = "detail"

    public var nsError: NSError {
        let (code, detail): (Int, String) = switch self {
        case let .invalidPath(detail): (1, detail)
        case let .serveFailed(detail): (2, detail)
        case let .writeFailed(detail): (3, detail)
        case let .connection(detail): (4, detail)
        case .invalidated: (5, "invalidated")
        }
        return NSError(domain: Self.domain, code: code, userInfo: [Self.detailKey: detail, NSLocalizedDescriptionKey: "\(self)"])
    }

    public init(_ error: NSError) {
        let detail = error.userInfo[Self.detailKey] as? String ?? error.localizedDescription
        switch (error.domain, error.code) {
        case (Self.domain, 1): self = .invalidPath(detail)
        case (Self.domain, 2): self = .serveFailed(detail)
        case (Self.domain, 3): self = .writeFailed(detail)
        case (Self.domain, 5): self = .invalidated
        default: self = .connection(detail)
        }
    }
}
