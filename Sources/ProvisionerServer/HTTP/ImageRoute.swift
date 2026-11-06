import Foundation
import Hummingbird
import NIOFileSystem
import ServiceLifecycle

/// `GET /pxe/{name}/{file}`: the boot image for one queued machine, so its
/// download is recorded against that machine.
func addImageRoute(to router: Router<some RequestContext>, provisioner: Provisioner) {
    router.get("/pxe/{name}/{file}") { _, context -> Response in
        guard let name = context.parameters.get("name"), let file = context.parameters.get("file"),
              let image = await provisioner.bootImage(for: name, file: file) else {
            throw HTTPError(.notFound)
        }
        let open = try await OpenImage(image.url)
        let body = ResponseBody(contentLength: open.size) { writer in
            // The stream runs in a child task so graceful shutdown can cancel a write
            // waiting on a client that stopped reading. This task only waits for it,
            // so the child is the writer's one user.
            nonisolated(unsafe) var writer = writer
            try await cancelWhenGracefulShutdown {
                try await stream(open, as: name, to: &writer, provisioner: provisioner)
            }
        }
        return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: body)
    }
}

/// Writes the image and records the download against `name`. A disconnect or
/// graceful shutdown ends it early, and the bytes sent so far are recorded.
private func stream(_ image: OpenImage, as name: String, to writer: inout any ResponseBodyWriter,
                    provisioner: Provisioner) async throws {
    let download = await provisioner.downloadStarted(name, total: image.size)
    var sent = 0
    do {
        for try await chunk in image.handle.readChunks(in: 0..<Int64(image.size), chunkLength: .mebibytes(1)) {
            try await writer.write(chunk)
            sent += chunk.readableBytes
            if let download { await provisioner.downloadProgressed(download, bytes: sent) }
        }
        guard sent == image.size else { throw ImageShrank() }
        try await writer.finish(nil)
    } catch {
        if let download { await provisioner.downloadEnded(download, bytes: sent) }
        throw error
    }
    if let download { await provisioner.downloadEnded(download, bytes: sent) }
}

private struct ImageShrank: Error {}

/// The image open for one response, its size read from the open file. The handle
/// closes when the response body is released, whether or not it was written.
private final class OpenImage: Sendable {
    let handle: ReadFileHandle
    let size: Int

    init(_ url: URL) async throws {
        let handle = try await FileSystem.shared.openFile(forReadingAt: .init(url.path), options: .init())
        do {
            size = Int(try await handle.info().size)
        } catch {
            try? await handle.close()
            throw error
        }
        self.handle = handle
    }

    deinit {
        let handle = handle
        Task { try? await handle.close() }
    }
}
