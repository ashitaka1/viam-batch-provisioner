# TCOS Machine Provisioning

PXE-based zero-touch provisioning system for System76 Meerkats as Viam robotics hosts.

## Architecture

Read `SPEC.md` before writing any code. It contains every design decision, the complete operator workflow, Docker Compose layout, autoinstall configuration, credential model, file structure, and implementation order. Follow the implementation order listed there.

## Key Design Constraints

- **Org API keys never touch target machines.** Per-machine credentials only. The provisioning script creates machines in Viam, retrieves per-machine cloud credentials, and stages them on the PXE server. Targets fetch their own credentials by MAC address during install.
- **No interactive steps on the target.** iPXE script goes straight to autoinstall, no menu. Ubuntu autoinstall runs unattended. First-boot services (Tailscale join) run without prompts.
- **Naming is deterministic by PXE boot arrival order.** The PXE watcher assigns pre-created Viam machine names to MACs in the order they appear. The operator controls ordering by powering on machines one at a time.
- **Secrets stay out of git.** SSH keys, Tailscale auth keys, and Viam credentials live in `config/` which is gitignored. Example files show the expected format.

## Stack

- **netboot.xyz** (Docker) — TFTP + iPXE bootloader
- **nginx** (Docker) — HTTP server for Ubuntu installer files, autoinstall configs, per-machine credentials
- **pxe-watcher** (Docker or host script) — Sniffs DHCP for PXE clients, assigns names
- **Viam CLI** — Used by `provision-batch.sh` to create machines and retrieve credentials
- **Ubuntu Server 24.04 autoinstall** — cloud-init based unattended install

## Target Machine Config

- User: `viam` / `checkmate`
- Headless (`multi-user.target`)
- Timezone: `America/New_York`
- Networking: dual-NIC (uplink=DHCP, robotnet=192.168.20.1/24), WiFi SSID `Viam`
- Packages: openssh-server, curl, jq, net-tools, NetworkManager, unattended-upgrades, mosh, speedtest-cli, tailscale
- Tailscale auto-join on first boot (key read from config, deleted after use)
- NIC interface names TBD — operator needs to run `ip link` on one Meerkat and update `config/network.conf`

## Raspberry Pi

Same project, different delivery mechanism. Pis use SD card flashing instead of PXE. The `provision-batch.sh` script is shared — `--type meerkat` stages credentials on the PXE server, `--type pi` stages them locally for the SD flash script. `flash-pi-sd.sh` writes the OS image, mounts the card, applies config (user, password, SSH key, WiFi, hostname, viam.json), and writes a first-boot script for packages and Tailscale. See the "Raspberry Pi (SD Card Workflow)" section of SPEC.md for full details.

Implementation order: build Meerkat PXE first (Phase 1), then Pi SD flashing (Phase 2).
