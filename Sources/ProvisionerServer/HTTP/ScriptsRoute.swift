import Hummingbird
import ProvisionerAPI

/// `GET /scripts/{file}`: the scripts the autoinstall late-commands fetch, from
/// `http-server/scripts/`, compiled in through the symlinks in `Sources/ProvisionerServer/`.
func addScriptsRoute(to router: Router<some RequestContext>) {
    let scripts = [
        "install-report.sh": PackageResources.install_report_sh,
        "post-install.sh": PackageResources.post_install_sh,
    ]
    router.get("/scripts/{file}") { _, context -> Response in
        guard let file = context.parameters.get("file"), let script = scripts[file] else {
            throw HTTPError(.notFound)
        }
        return Response(status: .ok, headers: [.contentType: "text/x-shellscript; charset=utf-8"],
                        body: .init(byteBuffer: ByteBuffer(bytes: script)))
    }
}
