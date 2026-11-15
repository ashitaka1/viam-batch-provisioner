import NIOCore
import NIOPosix
import Testing
@testable import ProvisionerPXE

struct PortHolderTests {
    /// UDP 1 (tcpmux) is bound by nothing on macOS; a freed ephemeral port could be taken by a parallel test.
    @Test func unboundPortHasNoHolder() {
        #expect(PortHolder.udp(port: 1) == nil)
    }

    @Test func tcpListenerIsNotAUDPHolder() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        #expect(PortHolder.udp(port: listener.localAddress!.port!) == nil)
        try await listener.close()
    }

    /// launchd runs as root, as bootpd does; its name is visible to an unprivileged test process.
    @Test func findsAnotherUsersProcessByName() {
        #expect(PortHolder.running(named: "launchd") == 1)
        #expect(PortHolder.running(named: "no-such-process-139") == nil)
    }
}
