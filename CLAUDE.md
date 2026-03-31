# Viam Lab Provisioner

PXE-based zero-touch provisioning system for x86 Linux machines as Viam robotics hosts.

## Architecture

Read `SPEC.md` for the original design brief. Note that implementation diverged in several areas based on real-world testing — this file reflects the actual working system.

### Boot chain

UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB (network boot) → Ubuntu kernel + initrd via TFTP → installer downloads ISO via HTTP → Ubuntu autoinstall runs unattended → late-commands fetch per-machine identity + credentials from HTTP server → first boot with viam-agent + Tailscale

### Components

- **dnsmasq** (native, not Docker) — proxy DHCP for PXE boot discovery + TFTP for GRUB, kernel, and initrd
- **nginx** (Docker) — HTTP server for Ubuntu ISO, autoinstall configs, per-machine credentials, Tailscale key
- **pxe-watcher** (host script) — sniffs DHCP for PXE clients, assigns names to MACs in arrival order
- **provision-batch.sh** — creates machines in Viam cloud via CLI, fetches cloud credentials via Python SDK
- **build-config.sh** — generates autoinstall user-data from template + secrets
- **setup-pxe-server.sh** — extracts GRUB, kernel, initrd, and modules from Ubuntu ISO

### Key design decisions (diverged from SPEC)

- **No netboot.xyz or iPXE.** GRUB handles network boot directly. netboot.xyz had a hardcoded menu server that couldn't be overridden; iPXE added unnecessary two-stage DHCP complexity.
- **dnsmasq runs natively, not in Docker.** Docker Desktop for Mac can't do host networking for broadcast DHCP/TFTP. This applies to any macOS PXE server.
- **NIC names discovered at install time.** No hardcoded interface names — late-commands detect uplink (DHCP lease), robotnet (other `enp*`), and WiFi (`wl*`) dynamically.
- **Provisioning key pattern.** An org-scoped API key (not the machine's own key) fetches per-machine cloud credentials via the Python SDK's `get_robot_part()`. The org key never touches target machines.
- **Tailscale key fetched from HTTP server at install time.** Not baked into user-data — changing the key doesn't require regenerating configs.
- **Boot order reset after install.** `efibootmgr` in late-commands moves disk above network boot, preventing accidental re-provisioning.
- **Ubuntu live server requires `url=` for ISO fetch.** The kernel + initrd are just the bootstrap; the full installer lives in the ISO's squashfs.

## Key Design Constraints

- **Org API keys never touch target machines.** Per-machine credentials only.
- **No interactive steps on the target.** GRUB auto-selects autoinstall, Ubuntu installs unattended, first-boot services run without prompts.
- **Naming is deterministic by PXE boot arrival order.** Operator controls ordering by powering on machines one at a time.
- **Secrets stay out of git.** SSH keys, Tailscale auth keys, and Viam credentials live in `config/` which is gitignored.
- **Hardware-agnostic.** Works on any x86 UEFI machine that supports PXE boot. Prefix is a required parameter, not hardcoded.

## Target Machine Config

- User: `viam` / `checkmate`
- Headless (`multi-user.target`)
- Timezone: `America/New_York`
- Console font: Terminus 16x32 (readable on high-DPI displays)
- Networking: dynamic NIC discovery (uplink=DHCP, robotnet=192.168.20.1/24 if second NIC present, WiFi if present)
- Packages: openssh-server, curl, jq, net-tools, NetworkManager, unattended-upgrades, mosh, speedtest-cli
- Viam CLI + viam-agent installed via binary download in late-commands
- Tailscale installed via official install script, first-boot join with auth key (deleted after use)

## Operator Workflow

```bash
make setup          # extract ISO contents (one-time)
make build-config   # generate autoinstall from template + secrets
make up             # start HTTP server (Docker)
make dhcp           # start dnsmasq proxy DHCP + TFTP (native)
make watch          # start PXE watcher (assigns names to MACs)
make status         # show queue state + service status

# provision-batch.sh creates machines + stages credentials
./scripts/provision-batch.sh --config config/my-batch.env
# or: ./scripts/provision-batch.sh --count 6 --prefix lab-meerkat --org-id ... --location-id ...
```

## Raspberry Pi

Phase 2 — not yet implemented. Pis use SD card flashing instead of PXE. The `provision-batch.sh` script is shared for Viam machine creation; delivery mechanism differs.
