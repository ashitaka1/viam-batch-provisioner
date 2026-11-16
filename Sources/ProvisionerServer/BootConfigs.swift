/// `grub/grub.cfg` in the TFTP root. A machine with a boot config at
/// `grub/boot/<its MAC>.cfg` follows it; any other boots from local disk after
/// the timeout, or into the stock interactive installer when someone picks it.
func menuConfig(port: Int, bootImagePath: String?) -> String {
    var text = """
        set timeout=5
        set default=disk
        source grub/boot/${net_default_mac}.cfg
        menuentry "Boot from local disk" --id=disk {
            exit
        }

        """
    if let bootImagePath {
        text += """
            menuentry "Ubuntu installer (interactive)" --id=installer {
                linux /hwe-vmlinuz ip=dhcp url=http://${net_default_server}:\(port)/\(bootImagePath) nomodeset vga=791 ---
                initrd /hwe-initrd
            }

            """
    }
    return text
}

/// A bound machine's boot config while it isn't installed: its autoinstall, with
/// its seed path and name on the kernel command line and its image URL.
func installBootConfig(name: String, token: String, port: Int, imageFile: String) -> String {
    let server = "http://${net_default_server}:\(port)"
    return """
        set timeout=1
        set default=install
        menuentry "Install \(name)" --id=install {
            linux /hwe-vmlinuz ip=dhcp url=\(server)/pxe/\(name)/\(imageFile) autoinstall cloud-config-url=/dev/null ds=nocloud-net\\;s=\(server)/machines/by-name/\(name)/\(token)/ viam_hostname=\(name) nomodeset vga=791 quiet ---
            initrd /hwe-initrd
        }

        """
}

/// An installed machine's boot config: GRUB returns to the firmware, which boots the disk.
let exitBootConfig = "exit\n"
