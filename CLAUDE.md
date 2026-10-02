# Viam Batch Provisioner

Zero-touch provisioning for x86 Linux machines (PXE or USB stick) and Raspberry Pis (SD card) as Viam robotics hosts.

## v2 Direction

A client-server rewrite (Swift server + SwiftUI client apps, REST + SSE from an OpenAPI contract) is planned in `docs/architecture-v2.md`, including phasing and open questions. Read it before starting new feature work. The existing bash/Python tooling below remains the working system until v2 replaces it — don't break it.

Phase 1 (persistent server on the current stack) is implemented: stateless watcher, append-only queue via `queue_store.py`, launchd daemons. Phase 2 (OpenAPI contract + Python REST/SSE) is next.

## Configuration

All site-specific settings live in `config/site.env` (gitignored). Run `just setup-wizard` to create it interactively. Settings include: machine prefix/count, username/password, WiFi, SSH key, Viam Cloud credentials (optional), Tailscale (optional).

Three provision modes:
- **full** — creates machines in Viam, installs viam-agent, deploys credentials
- **agent** — installs viam-agent binary, user adds credentials themselves
- **os-only** — just configures the OS, no Viam software

## Architecture

### x86 PXE Boot Chain

UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB → Ubuntu kernel + initrd via TFTP → installer downloads ISO via HTTP → Ubuntu autoinstall → late-commands fetch identity + credentials → first boot with viam-agent + Tailscale

### x86 USB Stick Boot Chain

UEFI USB boot → GRUB on stick → kernel + initrd from stick → installer downloads ISO via HTTP at the IP baked into grub.cfg → Ubuntu autoinstall → late-commands read `viam_hostname=` from kernel cmdline and fetch credentials from `/machines/by-name/<name>/` → first boot. No DHCP proxy, no TFTP, no PXE watcher — only the HTTP server runs. Use this when multiple operators share a network (PXE proxies would conflict) or when the LAN's DHCP server is locked down.

### Raspberry Pi SD Card

`flash-pi-sd.sh` writes OS image → mounts FAT32 boot partition → writes cloud-init user-data, network-config, meta-data → first boot runs Phase 2 service for network-dependent setup (packages, viam-agent, Tailscale)

### Components

- **dnsmasq** (native, not Docker) — proxy DHCP + TFTP for PXE boot
- **nginx** (Docker) — HTTP server for ISO, autoinstall configs, credentials
- **pxe-watcher** (host script, root) — assigns names to MACs as machines PXE boot; tails the nginx access log and writes GRUB guards on hostname fetch or repeat PXE
- **pxe-watcher/queue_store.py** — sole writer of `queue.json` (flock + atomic replace); imported by the watcher, called as a CLI by the bash scripts
- **scripts/daemon.sh** — renders `templates/launchd/*.plist.tpl` and installs dnsmasq + watcher as LaunchDaemons
- **scripts/tail-http-logs.sh** — pretty-prints `logs/access.log` (`just logs`); writes nothing
- **provision-batch.sh** — creates Viam machines + fetches credentials (full mode), or generates names-only queue (os-only/agent mode); appends to the existing queue
- **flash-pi-sd.sh** / **flash-batch.sh** — SD card flashing for Pis
- **flash-usb.sh** / **flash-usb-batch.sh** — x86 USB boot stick flashing (per-machine, fixed server)
- **pick-server-iface.sh** — scores host network interfaces; used by USB flash + serve-usb
- **build-config.sh** — generates PXE autoinstall user-data from template
- **setup-wizard.sh** — interactive config creation

### Key Design Decisions

- **GRUB, not netboot.xyz/iPXE.** GRUB handles network boot directly from the Ubuntu ISO's signed binary.
- **dnsmasq runs natively.** Docker Desktop for Mac can't do host networking for broadcast DHCP/TFTP.
- **NIC names discovered at install time.** Dynamic detection, no hardcoded interface names.
- **Provisioning key pattern.** Org-scoped API key fetches per-machine cloud credentials via Python SDK. The org key never touches target machines.
- **Pi OS uses cloud-init.** Pi OS Trixie has native cloud-init on the boot partition (FAT32, mountable from macOS). Two-phase boot: offline config first, network-dependent setup via systemd service.
- **Boot order reset after PXE install.** `efibootmgr` moves disk above network boot.
- **USB mode bakes identity into the bootloader.** Each stick's `grub.cfg` carries the host's `IP:port` and `viam_hostname=<name>` on the kernel cmdline, so the installer doesn't need a DHCP-watcher to learn its identity. Credentials are pre-staged at `/machines/by-name/<name>/viam.json` at flash time. The `user-data.tpl` late-commands try the cmdline first and fall back to MAC lookup, so the same template serves both modes.
- **USB layout: single FAT32 ESP, GPT.** GRUB is installed at `/EFI/BOOT/BOOTX64.EFI` (UEFI fallback path) so the stick boots on any UEFI firmware without per-machine boot entries.
- **Best-interface picker.** `pick-server-iface.sh` enumerates UP IPv4 interfaces, prefers the default-route one, then wired (`en*`/`eth*`/`enp*`) over wireless. Operator confirms the choice once per batch.
- **Server address persisted between flash and serve.** `flash-usb-batch.sh` writes the chosen `IP:port` to `config/.server-address` (gitignored). `just serve-usb` reads it so `build-config.sh` stamps the same address into `user-data` that's baked into the sticks.
- **The watcher holds no state in memory.** The queue is read from `queue.json` on every PXE event and a MAC's assignment time comes from its `machine-info.json`, so `just provision`, `just reset` and `just clean` take effect on a running daemon. A MAC that arrives with no slot is not remembered; it is assigned once the queue has an entry.
- **Append-only queue.** `provision` adds `COUNT` machines after the highest existing `<prefix>-N`; names already queued are skipped. `just clean` is the only wipe. Full-mode slot dirs are `slot-<name>` so two prefixes never collide.
- **One guard writer.** nginx writes its access log to `logs/access.log` (mounted at `/var/log/pxe`, outside the served `/srv` tree). The root watcher tails it and writes the guard on `GET /machines/<mac>/hostname` 200, and also on a repeat PXE more than 60s after assignment.
- **Daemon files take the operator's ownership.** Everything the root watcher creates is chowned to the owner of `http-server/machines/`, so user-run scripts can still write the queue.
- **launchd, not the venv.** Daemons run the watcher with a stable system or Homebrew `python3` (≥3.9; the code avoids 3.10-only syntax). The serving interface is baked into the plist at install because default-route detection fails at boot. dnsmasq is stopped by pid file, never `killall`.

## Operator Workflow

```bash
# First-time setup
just setup-wizard       # create config/site.env interactively

# Raspberry Pi provisioning
just download-pi-image  # one-time
just provision          # generate queue (or create Viam machines in full mode)
just flash-batch        # flash all SD cards with swap prompts

# x86 PXE provisioning
just setup              # extract GRUB + kernel from Ubuntu ISO (one-time)
just provision          # create Viam machines + stage credentials (appends to queue)
just serve              # start HTTP + DHCP/TFTP + watcher (Ctrl-C stops all)

# x86 PXE, always-on server (launchd)
just serve-daemon       # once: install dnsmasq + watcher daemons, start HTTP
just provision          # any time while the daemons run
just daemon-status      # daemons, HTTP server, queue
just stop-daemon

# Tests
just test               # python3 -m unittest discover -s pxe-watcher

# x86 USB-stick provisioning (when sharing network with other operators)
just setup              # one-time
just provision          # create Viam machines + stage credentials
just flash-usb-batch    # pick server interface, then plug-in/wipe/write each stick
just serve-usb          # HTTP only, no DHCP/TFTP
```

## Target Machine Config

All configurable via `config/site.env`:
- User/password (default: viam/checkmate)
- Timezone (default: America/New_York)
- WiFi SSID + password (optional)
- SSH authorized key
- Headless (`multi-user.target`)
- Console font: Terminus 16x32
- Packages: from `config/environments/<env>.packages.txt` (seeded from `config/packages.txt.example`; per-env, gitignored)
- Viam CLI + viam-agent (full/agent mode)
- Tailscale auto-join (if auth key provided)
