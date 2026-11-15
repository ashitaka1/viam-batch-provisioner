import Testing
@testable import ProvisionerPXE

struct PXEServerErrorTests {
    @Test func onlyBootpdPointsAtAVirtualizationVM() {
        let bootpd = PXEServerError.portInUse(port: 67, holder: PortHolder(pid: 312, name: "bootpd")).description
        #expect(bootpd.contains("bootpd (pid 312)"), "\(bootpd)")
        #expect(bootpd.contains("Virtualization.framework VM"), "\(bootpd)")
        let other = PXEServerError.portInUse(port: 67, holder: PortHolder(pid: 88, name: "dnsmasq")).description
        #expect(other.contains("dnsmasq (pid 88)"), "\(other)")
        #expect(!other.contains("Virtualization"), "\(other)")
    }

    @Test func inferredBootpdIsNamedAsLikely() {
        let message = PXEServerError.portInUse(port: 67, holder: PortHolder(pid: 312, name: "bootpd", confirmed: false)).description
        #expect(message.contains("most likely by bootpd (pid 312)"), "\(message)")
        #expect(message.contains("Virtualization.framework VM"), "\(message)")
    }
}
