import Foundation
import Hummingbird
import Logging
import OpenAPIRuntime

/// Gives every API error a contract `Error` body: request-decoding failures
/// from the generated layer, unmatched routes, and anything unexpected.
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    let logger: Logger

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.uri.path.hasPrefix("/api/") else { return try await next(request, context) }
        do {
            return try await next(request, context)
        } catch let error as ServerError {
            if let decoding = Self.decodingError(error), case .dataCorrupted(let context) = decoding,
               context.codingPath.isEmpty {
                return errorResponse(.badRequest, .invalidJson, "request body is not valid JSON")
            }
            return errorResponse(.badRequest, .invalidRequest, "invalid request: \(Self.describe(error))")
        } catch let error as HTTPError {
            switch error.status {
            case .notFound: return errorResponse(.notFound, .notFound, "no such endpoint")
            case .methodNotAllowed: return errorResponse(.methodNotAllowed, .methodNotAllowed, "method not allowed")
            case .contentTooLarge: return errorResponse(.contentTooLarge, .payloadTooLarge, "body too large")
            default: return errorResponse(error.status, .invalidRequest, error.body ?? "\(error.status)")
            }
        } catch {
            logger.error("request \(request.method) \(request.uri.path) failed: \(error)")
            return errorResponse(.internalServerError, ._internal, "internal error")
        }
    }

    private static func decodingError(_ error: ServerError) -> DecodingError? {
        var current: (any Error)? = error.underlyingError
        while let error = current {
            if let decoding = error as? DecodingError { return decoding }
            current = (error as? ServerError)?.underlyingError
        }
        return nil
    }

    private static func describe(_ error: ServerError) -> String {
        if let decoding = decodingError(error) {
            switch decoding {
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default:
                return "\(decoding)"
            }
        }
        return "\(error.underlyingError)"
    }
}
