import Foundation
import Hummingbird

/// `GET /machines/by-name/{name}/{token}/{file}`: one machine's cloud-init seed
/// and secrets. Failures carry no body, so a wrong token learns nothing.
func addSeedRoute(to router: Router<some RequestContext>, provisioner: Provisioner) {
    router.get("/machines/by-name/{name}/{token}/{file}") { request, context -> Response in
        guard let name = context.parameters.get("name"), let token = context.parameters.get("token"),
              let file = context.parameters.get("file") else {
            throw HTTPError(.notFound)
        }
        let data: Data
        do {
            data = try await provisioner.seedFile(file, name: name, token: token, host: request.head.authority)
        } catch let failure as SeedFailure {
            switch failure {
            case .notFound: throw HTTPError(.notFound)
            case .badHost: throw HTTPError(.badRequest)
            case .unsaved: throw HTTPError(.internalServerError)
            }
        }
        return Response(status: .ok,
                        headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
