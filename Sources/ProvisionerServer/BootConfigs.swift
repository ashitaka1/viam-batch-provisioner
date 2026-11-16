import Logging

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

/// The boot config `record` calls for: none while unbound, `exit` once installed,
/// otherwise its install entry.
func bootConfig(for record: QueueRecord, store: MachineStore, port: Int, bootImage: BootImage?) -> String? {
    guard record.mac != nil, let bootImage, let token = store.token(record.key) else { return nil }
    if derivedStatus(store.machine(record.key), bound: true) == .installed { return exitBootConfig }
    return installBootConfig(name: record.name, token: token, port: port, imageFile: bootImage.fileName)
}

/// Writes the menu and every bound entry's boot config, after clearing the old
/// ones. Failures are logged and the server serves on.
func rewriteBootConfigs(_ store: MachineStore, port: Int, bootImage: BootImage?, logger: Logger) {
    do {
        try store.writeMenu(menuConfig(port: port, bootImagePath: bootImage?.path))
        try store.clearBootConfigs()
    } catch {
        logger.error("writing the boot menu failed: \(error)")
    }
    for record in store.queue {
        guard let mac = record.mac else { continue }
        do {
            try store.writeBootConfig(bootConfig(for: record, store: store, port: port, bootImage: bootImage), mac: mac)
        } catch {
            logger.error("writing the boot config of \(record.name) failed: \(error)")
        }
    }
}

extension Provisioner {
    /// Rewrites `record`'s boot config to match its state; a failure is logged.
    func refreshBootConfig(_ record: QueueRecord, _ store: MachineStore) {
        guard let serverPort, let mac = record.mac else { return }
        do {
            try store.writeBootConfig(bootConfig(for: record, store: store, port: serverPort, bootImage: bootImage), mac: mac)
        } catch {
            logger.error("writing the boot config of \(record.name) failed: \(error)")
        }
    }

    /// Removes the boot config for `mac`; a failure is logged.
    func removeBootConfig(_ mac: String?, of name: String, _ store: MachineStore) {
        guard serverPort != nil, let mac else { return }
        do {
            try store.writeBootConfig(nil, mac: mac)
        } catch {
            logger.error("removing the boot config of \(name) failed: \(error)")
        }
    }
}
