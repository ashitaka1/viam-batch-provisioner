# Architecture Spec (Historical)

> **Note:** This was the original design brief. The implementation diverged in
> several significant ways based on real-world testing. See `CLAUDE.md` for
> the current architecture and `QUICKSTART.md` for the operator workflow.
>
> Key divergences: GRUB replaces netboot.xyz/iPXE, dnsmasq runs natively
> (not in Docker), NIC names are auto-detected (no network.conf), the
> `url=` kernel parameter is required for Ubuntu live server ISO fetch,
> and the provisioning key pattern differs from the original credential model.

## Purpose

Zero-touch provisioning of x86 Linux machines as Viam robotics hosts. A PXE server on the local network handles OS installation, machine naming, Viam registration, and all configuration. The operator's workflow is: unbox machines, plug them into Ethernet, power on, apply labels.

This document was the original implementation brief.

---

## Operator Workflow

```
1. Run the batch provisioning script on your workstation:
     ./provision-batch.sh --count 6 --prefix tcos-meerkat

   The script:
   - Queries Viam for existing machines matching prefix
   - Pre-creates the next N machines (e.g., tcos-meerkat-07 through tcos-meerkat-12)
   - Retrieves per-machine cloud credentials JSON
   - Stages credential files on the PXE server, keyed by "slot" (arrival order)
   - Prints: "Ready. Power on machines one at a time."

2. Plug Meerkats into Ethernet on the provisioning network.

3. Power on each Meerkat, holding F10 to select network boot.
   (Or: set USB/Network as first boot priority in BIOS once per Meerkat model,
   then just power on.)

4. The PXE watcher script prints to your terminal:
     [14:32:01] New PXE client: MAC AA:BB:CC:DD:EE:FF → assigned tcos-meerkat-07
     [14:32:18] New PXE client: MAC 11:22:33:44:55:66 → assigned tcos-meerkat-08
     ...

5. Each machine installs Ubuntu unattended (~10 min), reboots, and appears
   in app.viam.com with its assigned name.

6. The script outputs a final mapping for label printing:
     tcos-meerkat-07  AA:BB:CC:DD:EE:FF
     tcos-meerkat-08  11:22:33:44:55:66
     ...
```

---

## System Components

### 1. PXE Server (Docker Compose)

Runs on any Linux machine on the provisioning network. Could be the operator's workstation, a dedicated Pi, or one of the Meerkats.

**Services:**

| Container | Role | Ports |
|---|---|---|
| `netboot-xyz` | TFTP server + iPXE bootloader | UDP 69 (TFTP), TCP 3000 (web UI) |
| `http-server` | Serves Ubuntu kernel/initrd, autoinstall configs, and per-machine credentials | TCP 8080 |
| `pxe-watcher` | Monitors DHCP traffic for PXE boot requests, assigns names to MACs in arrival order | — (host network, listens on provisioning interface) |

**Note on DHCP:** The provisioning network must have a DHCP server. Most lab networks already do (router, etc.). The DHCP server needs to be configured to hand out PXE boot options (next-server + filename) pointing at the netboot-xyz container. Alternatively, netboot-xyz can run as a ProxyDHCP alongside an existing DHCP server — it responds only to PXE requests without interfering with normal DHCP. Document both options.

### 2. HTTP File Server Layout

```
http-server/
├── ubuntu/
│   ├── vmlinuz                    # Ubuntu 24.04 Server kernel
│   └── initrd                     # Ubuntu 24.04 Server initrd
├── autoinstall/
│   ├── user-data                  # Autoinstall template (common config)
│   └── meta-data                  # Empty file (required by cloud-init)
├── machines/
│   ├── <MAC-ADDRESS>/
│   │   ├── viam.json              # Per-machine Viam cloud credentials
│   │   ├── hostname               # Assigned hostname (e.g., tcos-meerkat-07)
│   │   └── machine-info.json      # Metadata (name, MAC, created timestamp)
│   └── ...
└── scripts/
    └── post-install.sh            # Downloaded and run by late-commands
```

### 3. iPXE Boot Script

The custom iPXE script served by netboot-xyz. No menu, no interaction — it chains directly into the Ubuntu autoinstall.

```ipxe
#!ipxe

# Set the HTTP server base URL
set base-url http://${next-server}:8080

# Load Ubuntu installer with autoinstall
kernel ${base-url}/ubuntu/vmlinuz initrd=initrd autoinstall ds=nocloud-net;s=${base-url}/autoinstall/ ip=dhcp quiet ---
initrd ${base-url}/ubuntu/initrd
boot
```

### 4. Autoinstall Configuration (user-data)

Single file served to all machines. Per-machine customization happens in `late-commands` by fetching the machine's credential file from the HTTP server using its own MAC address as the lookup key.

**Identity:**
- Username: `viam`
- Password: `checkmate` (hash with `mkpasswd -m sha-512`)
- No password change enforcement

**Locale/Timezone:**
- Locale: `en_US.UTF-8`
- Keyboard: `us`
- Timezone: `America/New_York`

**Storage:**
- Wipe largest non-install-media disk, LVM, use all space
- No special partition layout

**SSH:**
- Install OpenSSH server
- Password auth: yes
- Authorized key: read from `tcos_hosts_key.pub` on the PXE server, baked into user-data at ISO/config build time

**Packages:**
- `openssh-server`
- `curl`
- `jq`
- `net-tools`
- `NetworkManager`
- `unattended-upgrades`
- `mosh`
- `speedtest-cli`

**Packages requiring external repos (handle in late-commands):**
- `tailscale` — requires adding Tailscale's apt repo and key
- Any future additions

**Networking (Netplan, applied by autoinstall):**

For dual-NIC Meerkats (primary target):

```yaml
network:
  version: 2
  ethernets:
    uplink:
      match:
        name: "<UPLINK_IFACE_NAME>"    # TBD: discover on real hardware
      dhcp4: true
      dhcp6: true
    robotnet:
      match:
        name: "<ROBOTNET_IFACE_NAME>"  # TBD: discover on real hardware
      addresses:
        - 192.168.20.1/24
      dhcp4: false
  wifis:
    wlan0:
      access-points:
        "Viam":
          password: "checkmate"
      dhcp4: true
```

For single-NIC Meerkats (secondary profile — no robotnet):

```yaml
network:
  version: 2
  ethernets:
    uplink:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
  wifis:
    wlan0:
      access-points:
        "Viam":
          password: "checkmate"
      dhcp4: true
```

**TBD (requires hands-on discovery):** The exact interface names for uplink vs robotnet on dual-NIC Meerkats. Likely `enp1s0` (onboard, clustered ports) and `enp2s0` (expansion slot, lone port). Operator must run `ip link` on one unit to confirm. These values are then set in the autoinstall config.

**Late Commands (run during install, target at /target):**

1. Set timezone: `timedatectl set-timezone America/New_York`
2. Set default target: `multi-user.target` (headless)
3. Disable unneeded services: `gdm3`, `bluetooth`, `cups`
4. Fetch machine identity from PXE server:
   - Determine own MAC address
   - Normalize MAC (lowercase, colon-separated)
   - `curl http://<pxe-server>:8080/machines/<MAC>/hostname` → save as hostname
   - `curl http://<pxe-server>:8080/machines/<MAC>/viam.json` → save to `/target/etc/viam.json`
   - Set hostname in `/target/etc/hostname` and `/target/etc/hosts`
5. Install viam-agent:
   - `mkdir -p /target/opt/viam/bin`
   - Download `viam-agent-stable-x86_64` to `/target/opt/viam/bin/viam-agent`
   - Write systemd unit file for `viam-agent.service`
   - Enable service
6. Install Tailscale:
   - Add Tailscale apt repo and signing key to target
   - `chroot /target apt-get update && apt-get install -y tailscale`
   - Write a first-boot systemd service (`tcos-tailscale.service`) that runs:
     `tailscale up --authkey=<TAILSCALE_KEY> --hostname=<MACHINE_HOSTNAME>`
   - The Tailscale auth key is read from a file on the PXE server at config build time, NOT baked into the autoinstall — it's written into a config file on the target that the first-boot service reads and then deletes
7. Enable automatic security updates

### 5. Batch Provisioning Script (`provision-batch.sh`)

Runs on the operator's workstation (or the PXE server host). Requires:
- Viam CLI installed and authenticated
- Network access to Viam cloud API and the PXE server's HTTP service

**Arguments:**

| Flag | Description | Required |
|---|---|---|
| `--count N` | Number of machines to provision | Yes |
| `--prefix PREFIX` | Name prefix (default: `tcos-meerkat`) | No |
| `--location-id ID` | Viam location ID | Yes |
| `--pxe-server HOST` | PXE server address (default: `localhost`) | No |

**Flow:**

1. Authenticate with Viam CLI: `viam login api-key --key-id=... --key=...`
   (Or assume already authenticated.)
2. List existing machines: `viam machines list --location=<LOCATION_ID>`
3. Find highest existing number matching prefix.
4. For each new machine (highest+1 through highest+count):
   a. Create machine: `viam machines create --name=tcos-meerkat-NN --location=<LOCATION_ID>`
   b. Retrieve machine cloud credentials (the per-machine key pair — NOT the org key).
      **Note:** The exact CLI command to retrieve per-machine credentials needs verification.
      It may be `viam machines credentials --machine-id=<ID>` or require an API call.
      The goal is to get the `viam.json` content with machine-specific `id` and `secret`.
   c. Write credentials to PXE server: `http-server/machines/<slot>/viam.json`
      (Slot is a placeholder — the actual keying by MAC happens when the machine PXE boots.)
5. Queue the names in order on the PXE server (write to a file or API).
6. Print summary and wait for PXE boot events.

### 6. PXE Watcher (`pxe-watcher`)

A lightweight script (Python or bash + tcpdump) that:

1. Listens on the provisioning network interface for DHCP Discover packets with PXE client options (option 60 = "PXEClient", option 93 = client system architecture).
2. Extracts the source MAC address.
3. Checks if this MAC is already known (skip if so).
4. Assigns the next name from the provisioned queue.
5. Creates the MAC-keyed directory on the HTTP server:
   ```
   machines/<MAC>/hostname     ← the assigned name
   machines/<MAC>/viam.json    ← the pre-created credentials
   ```
6. Prints to stdout: `[timestamp] New PXE client: MAC <MAC> → assigned <name>`
7. After all queued names are assigned, prints the full mapping table for label printing.

**Race condition handling:** Machines are powered on one at a time (operator controls this). The watcher processes events sequentially. If two PXE discovers arrive in rapid succession, they're handled in order — first MAC gets the next name, second MAC gets the one after. This is deterministic as long as arrival order is consistent.

### 7. Credentials Model

**What lives where:**

| Secret | Location | Scope |
|---|---|---|
| Viam org API key | Operator's workstation only (used by `provision-batch.sh`) | Never on target machines |
| Viam per-machine credentials (`viam.json`) | PXE server → target machine's `/etc/viam.json` | One machine only |
| Tailscale auth key | PXE server config directory → target machine (deleted after first use) | Fleet-wide, single-use or reusable per Tailscale settings |
| SSH public key (`tcos_hosts_key.pub`) | PXE server config directory → baked into autoinstall user-data | Fleet-wide |
| User password (`checkmate`) | Baked into autoinstall user-data as SHA-512 hash | Fleet-wide |

**The org API key never leaves the operator's machine.** Per-machine credentials are generated by the provisioning script, staged on the PXE server, and served to the target during install. After install, the PXE server's copy can be archived or deleted.

---

## File Structure (Git Repository)

```
tcos-provisioning/
├── README.md                          # Operator runbook
├── SPEC.md                            # This document
├── docker-compose.yml                 # PXE server stack
├── config/
│   ├── tcos_hosts_key.pub             # SSH public key (operator provides)
│   ├── tailscale.key                  # Tailscale auth key (operator provides)
│   ├── viam-credentials.env           # VIAM_API_KEY_ID, VIAM_API_KEY, VIAM_LOCATION_ID
│   └── network.conf                   # NIC interface names (filled in after discovery)
├── netboot/
│   ├── custom-ipxe/
│   │   └── tcos-meerkat.ipxe          # Custom iPXE script (no menu, straight to install)
│   └── menus/                         # netboot.xyz custom menu overrides if needed
├── http-server/
│   ├── Dockerfile                     # Nginx or Python HTTP server
│   ├── ubuntu/                        # Kernel + initrd extracted from Ubuntu ISO
│   │   ├── vmlinuz
│   │   └── initrd
│   ├── autoinstall/
│   │   ├── user-data                  # Generated from template + config/
│   │   └── meta-data
│   ├── machines/                      # Per-machine dirs created at provision time
│   └── scripts/
│       └── post-install.sh            # Fetched by late-commands
├── pxe-watcher/
│   ├── Dockerfile                     # Or just a script
│   └── watcher.py                     # Listens for PXE DHCP, assigns names
├── scripts/
│   ├── provision-batch.sh             # Operator-facing batch provisioning script
│   ├── flash-pi-sd.sh                 # Pi-specific SD card flashing
│   ├── build-config.sh                # Generates user-data from template + config/
│   └── setup-pxe-server.sh            # One-time PXE server setup helper
└── templates/
    ├── user-data.tpl                  # Autoinstall template with placeholders
    ├── netplan-dual-nic.yaml          # Netplan template for dual-NIC Meerkats
    ├── netplan-single-nic.yaml        # Netplan template for single-NIC Meerkats
    ├── pi-firstboot.sh.tpl            # First-boot script template for Pis
    └── pi-cloud-init.yaml.tpl         # Alternative: cloud-init template for Ubuntu Pi
```

**`.gitignore` must exclude:**
- `config/tailscale.key`
- `config/viam-credentials.env`
- `config/tcos_hosts_key.pub`
- `http-server/machines/` (per-machine credentials)

Include `.env.example` / `*.example` files showing the expected format.

---

## Raspberry Pi (SD Card Workflow)

Pis use SD card flashing instead of PXE. They share the naming convention (`tcos-pi-NN`), the same `provision-batch.sh` for Viam machine creation, and the same packages/config — the only difference is the delivery mechanism.

### Operator Workflow (Pis)

```
1. Run the batch provisioning script:
     ./provision-batch.sh --count 3 --prefix tcos-pi --type pi

   Same as Meerkat flow: creates machines in Viam, retrieves per-machine credentials.
   Additionally downloads the Pi SD card base image if not cached locally.

2. For each machine, run the SD card flashing script:
     ./scripts/flash-pi-sd.sh /dev/sdX tcos-pi-04

   The script:
   - Writes Raspberry Pi OS (or Ubuntu Server arm64) to the SD card
   - Mounts the card's boot and root partitions
   - Runs Viam's preinstall.sh to install viam-agent
   - Writes /etc/viam.json with that machine's specific credentials
   - Writes the same common config: user/password, SSH key, WiFi,
     timezone, packages, Tailscale auth key
   - Sets hostname to tcos-pi-04
   - Unmounts. Card is ready.

3. Insert SD card into Pi, power on. Pi boots, Tailscale joins,
   viam-agent connects. No interaction needed.
```

### Pi-Specific Configuration

**Base OS:** Raspberry Pi OS Lite (64-bit) or Ubuntu Server 24.04 arm64. Operator choice — the flash script supports either.

**Identity:** Same as Meerkats — user `viam`, password `checkmate`, SSH key authorized.

**Networking:** Single Ethernet (DHCP), WiFi SSID `Viam` / `checkmate`. No robotnet interface.

**Packages:** Same as Meerkats minus anything x86-specific. The `speedtest-cli`, `tailscale`, `mosh`, `curl`, `jq`, `net-tools`, `unattended-upgrades` packages are all available on arm64.

**viam-agent binary:** `viam-agent-stable-aarch64` instead of `x86_64`.

**Tailscale:** Same first-boot join service. Auth key read from `config/tailscale.key`, written to the SD card, deleted after first use.

### Flash Script (`scripts/flash-pi-sd.sh`)

**Arguments:**

| Arg | Description |
|---|---|
| `$1` | Block device (e.g., `/dev/sdb`) |
| `$2` | Machine name (e.g., `tcos-pi-04`) — must already be created by `provision-batch.sh` |

**Flow:**

1. Write base OS image to SD card with `dd` (or use `rpi-imager` CLI if available).
2. Mount boot partition and root partition.
3. Configure `firstrun.sh` or cloud-init (depending on base OS) for:
   - Hostname
   - User `viam` with password hash
   - SSH authorized key
   - WiFi config
   - Timezone
   - Locale
4. Download Viam's `preinstall.sh` and run it against the mounted root, providing:
   - `VIAM_JSON_PATH` pointing at the pre-created machine's credentials file
   - No `viam-defaults.json` (no fragments, no captive portal)
5. Install additional packages by chrooting into the rootfs (using `qemu-user-static` for arm64 emulation on x86 host) or by writing a first-boot script that runs `apt-get install` on first boot.
6. Write Tailscale first-boot join service and auth key file.
7. Unmount and sync.

**Note on cross-architecture package installation:** If the PXE/build server is x86, installing arm64 packages via chroot requires `qemu-user-static` and `binfmt-support`. The simpler alternative is a first-boot script that installs packages on the Pi itself — slower on first boot but avoids cross-arch complexity. Recommend the first-boot approach.

### File Structure Additions

```
tcos-provisioning/
├── scripts/
│   ├── provision-batch.sh             # Shared — works for both Meerkats and Pis
│   └── flash-pi-sd.sh                 # Pi-specific SD card flashing
├── templates/
│   ├── pi-firstboot.sh.tpl            # First-boot script template for Pis
│   └── pi-cloud-init.yaml.tpl         # Alternative: cloud-init template for Ubuntu Pi
└── config/
    └── pi-base-image.conf             # URL or path to Pi base OS image
```

---

## Future Extensions (Parked)

- **Fragment support:** Add `--fragment-id` to `provision-batch.sh` and write it into `viam-defaults.json` on the target. For now, machines are provisioned blank.
- **GUI variant:** Add a second autoinstall template that installs `ubuntu-desktop-minimal` and sets `graphical.target`. Select via a flag on the provisioning script.
- **Golden image capture:** Use FOG or Clonezilla to capture a fully-configured Meerkat and stamp it onto new hardware. Only worthwhile at higher fleet volumes.
- **Per-machine hardware profiles:** Support different NIC configurations, device tree overlays, etc. via the MAC-keyed config directory on the PXE server.

---

## Implementation Order

### Phase 1: Meerkat PXE Provisioning

1. **Set up the git repo** with the directory structure above.
2. **Docker Compose:** netboot-xyz container + nginx HTTP server container. Get a basic PXE boot working (even just to the netboot.xyz default menu) to validate TFTP/DHCP.
3. **Custom iPXE script:** Replace the default menu with the no-interaction boot script pointing at the HTTP server.
4. **Autoinstall template + build script:** Generate `user-data` from the template, injecting SSH key, password hash, timezone, packages. Test a full unattended Ubuntu install via PXE on one Meerkat.
5. **Per-machine credential serving:** Implement the MAC-keyed directory structure on the HTTP server. Update `late-commands` to fetch hostname + `viam.json` by MAC.
6. **PXE watcher:** Implement the DHCP sniffer that assigns names to MACs.
7. **Batch provisioning script:** Wire up Viam CLI machine creation + credential retrieval + PXE server staging.
8. **Tailscale integration:** Add repo setup + first-boot join to late-commands.
9. **Network config discovery:** Run `ip link` on a real dual-NIC Meerkat, fill in `config/network.conf`, update Netplan template.
10. **End-to-end test (Meerkat):** Provision a batch of 2-3 Meerkats, verify naming, Viam registration, Tailscale, SSH access.

### Phase 2: Raspberry Pi SD Card Provisioning

11. **Pi flash script:** Write `flash-pi-sd.sh` — downloads base image (if not cached), writes to SD, mounts, applies config.
12. **Pi first-boot script template:** Packages, Tailscale join, hostname, SSH key, WiFi — everything that can't be done at flash time without cross-arch chroot.
13. **Wire Pi into `provision-batch.sh`:** Add `--type pi` flag. Same Viam machine creation, credentials staged locally instead of on PXE server.
14. **End-to-end test (Pi):** Flash an SD card, boot a Pi, verify naming, Viam registration, Tailscale, SSH.

### Phase 3: Documentation

15. **Write the operator runbook** (README.md) covering both Meerkat and Pi workflows.

---

## Open Items (Require Operator Input)

- [ ] Exact NIC interface names on dual-NIC Meerkat (step 9 above)
- [ ] Viam CLI command to retrieve per-machine credentials after creation (needs verification)
- [ ] Which network interface the PXE server should listen on
- [ ] Whether the PXE server machine is dedicated or shared (affects Docker networking)
- [ ] Tailscale auth key type: single-use per machine, or reusable?
