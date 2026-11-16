import Foundation
import Hummingbird
import Logging

/// The file tree targets fetch, at `/`. Paths under `/api/`, `/pxe/` and
/// `/machines/` belong to the router and are never looked up on disk.
/// `/config/` and `/autoinstall/` are where the Python tooling stages the shared
/// Tailscale key and a shared user-data holding the WiFi password; they get 404.
struct StaticFiles<Context: RequestContext>: RouterMiddleware {
    private let files: FileMiddleware<Context, LocalFileSystem>

    init(root: String, logger: Logger) {
        files = FileMiddleware(root, searchForIndexHtml: false, logger: logger)
    }

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        if path.hasPrefix("/api/") || path.hasPrefix("/pxe/") || path.hasPrefix("/machines/") {
            return try await next(request, context)
        }
        if let top = topDirectory(path), Self.neverOnDisk.contains(top) {
            throw HTTPError(.notFound)
        }
        return try await files.handle(request, context: context, next: next)
    }

    private static var neverOnDisk: Set<String> { ["api", "pxe", "machines", "config", "autoinstall"] }
}

/// The first directory `path` names once it is read the way a file lookup reads
/// it: percent-decoded, empty and `.` segments dropped, `..` applied, and
/// lowercased, since the volume may ignore case. Nil for a file at the root.
func topDirectory(_ path: String) -> String? {
    let decoded = path.removingPercentEncoding ?? path
    var segments: [Substring] = []
    for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
        switch segment {
        case ".": continue
        case "..": _ = segments.popLast()
        default: segments.append(segment)
        }
    }
    return segments.count > 1 ? segments[0].lowercased() : nil
}
