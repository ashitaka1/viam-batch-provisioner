import Foundation
import Hummingbird

private let chunkSize = 1 << 20

/// `GET /pxe/{name}/{file}`: the boot image for one queued machine, so its
/// download is recorded against that machine.
func addImageRoute(to router: Router<some RequestContext>, provisioner: Provisioner) {
    router.get("/pxe/{name}/{file}") { _, context -> Response in
        guard let name = context.parameters.get("name"), let file = context.parameters.get("file"),
              let image = await provisioner.bootImage(for: name, file: file) else {
            throw HTTPError(.notFound)
        }
        let handle = try FileHandle(forReadingFrom: image.url)
        let body = ResponseBody(contentLength: image.size) { writer in
            defer { try? handle.close() }
            await provisioner.downloadStarted(name, total: image.size)
            var sent = 0
            do {
                while sent < image.size,
                      let chunk = try handle.read(upToCount: min(chunkSize, image.size - sent)), !chunk.isEmpty {
                    try await writer.write(ByteBuffer(bytes: chunk))
                    sent += chunk.count
                    await provisioner.downloadProgressed(name, bytes: sent)
                }
                try await writer.finish(nil)
            } catch {
                await provisioner.downloadEnded(name, bytes: sent)
                throw error
            }
            await provisioner.downloadEnded(name, bytes: sent)
        }
        return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: body)
    }
}
