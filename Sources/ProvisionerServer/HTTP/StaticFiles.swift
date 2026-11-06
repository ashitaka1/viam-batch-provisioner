import Hummingbird
import Logging

/// The file tree targets fetch, at `/`. Paths under `/api/` and `/pxe/` belong
/// to the router and are never looked up on disk.
struct StaticFiles<Context: RequestContext>: RouterMiddleware {
    private let files: FileMiddleware<Context, LocalFileSystem>

    init(root: String, logger: Logger) {
        files = FileMiddleware(root, searchForIndexHtml: false, logger: logger)
    }

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        if request.uri.path.hasPrefix("/api/") || request.uri.path.hasPrefix("/pxe/") {
            return try await next(request, context)
        }
        return try await files.handle(request, context: context, next: next)
    }
}
