import Foundation
import Hummingbird
import Logging

/// Logs each request's method, path, status and duration. The seed route's token is a secret, so its
/// path segment is logged as `<token>`, and no query string is logged.
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let logger: Logger

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let path = Self.loggedPath(request.uri.path)
        do {
            let response = try await next(request, context)
            logger.info("\(request.method) \(path) \(response.status.code) \(Self.milliseconds(since: start)) ms")
            return response
        } catch let error as HTTPResponseError {
            logger.info("\(request.method) \(path) \(error.status.code) \(Self.milliseconds(since: start)) ms")
            throw error
        } catch {
            logger.info("\(request.method) \(path) failed after \(Self.milliseconds(since: start)) ms")
            throw error
        }
    }

    /// `path` with the token segment of `/machines/by-name/{name}/{token}/…` replaced. The router ignores
    /// empty segments, so this does too: `//machines//by-name/…` reaches the seed route.
    static func loggedPath(_ path: String) -> String {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let nonEmpty = segments.indices.filter { !segments[$0].isEmpty }
        if nonEmpty.count > 3, segments[nonEmpty[0]] == "machines", segments[nonEmpty[1]] == "by-name" {
            segments[nonEmpty[3]] = "<token>"
        }
        return segments.joined(separator: "/")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}
