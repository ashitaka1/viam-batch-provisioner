import Foundation
@testable import ProvisionerServer
import Testing

@Test func installBootConfigCarriesSeedPathNameAndImageURL() {
    let token = String(repeating: "a", count: 32)
    let text = installBootConfig(name: "m-1", token: token, port: 8234, imageFile: testImageName)
    #expect(text.contains("set default=install"))
    #expect(text.contains("set timeout=1"))
    #expect(text.contains("url=http://${net_default_server}:8234/pxe/m-1/\(testImageName)"))
    #expect(text.contains(#"ds=nocloud-net\;s=http://${net_default_server}:8234/machines/by-name/m-1/\#(token)/ viam_hostname=m-1"#))
    #expect(text.contains("linux /hwe-vmlinuz ip=dhcp "))
    #expect(text.contains("initrd /hwe-initrd"))
}

@Test func menuDefaultsToDiskAndSourcesTheBootConfig() {
    let text = menuConfig(port: 8234, bootImagePath: "ubuntu/u.iso")
    #expect(text.contains("set default=disk"))
    #expect(text.contains("set timeout=5"))
    #expect(text.contains("source grub/boot/${net_default_mac}.cfg"))
    #expect(text.contains(#"menuentry "Boot from local disk" --id=disk"#))
    #expect(text.contains("url=http://${net_default_server}:8234/ubuntu/u.iso"))
}

@Test func menuWithoutABootImageOffersNoInstaller() {
    #expect(!menuConfig(port: 8234, bootImagePath: nil).contains("--id=installer"))
}

@Test func bootImageKeepsItsPath() throws {
    let files = try temporaryDirectory()
    try FileManager.default.createDirectory(at: files.appending(path: "ubuntu"), withIntermediateDirectories: true)
    try Data("iso".utf8).write(to: files.appending(path: "ubuntu/\(testImageName)"))
    #expect(try BootImage(files: files, path: "ubuntu/\(testImageName)").path == "ubuntu/\(testImageName)")
}
