import Hummingbird

let maxRequestBody = 5 * 1024 * 1024
let maxReportBody = 16 * 1024

/// Refuses API POSTs without a Content-Length, or longer than their limit,
/// before the body is read.
struct BodyLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.method == .post, request.uri.path.hasPrefix("/api/") else {
            return try await next(request, context)
        }
        guard let text = request.headers[.contentLength], let length = Int(text) else {
            return errorResponse(.lengthRequired, .lengthRequired, "Content-Length is required")
        }
        let limit = request.uri.path == "/api/v1/install-reports" ? maxReportBody : maxRequestBody
        if length > limit {
            return errorResponse(.contentTooLarge, .payloadTooLarge, "body exceeds \(limit) bytes")
        }
        return try await next(request, context)
    }
}
