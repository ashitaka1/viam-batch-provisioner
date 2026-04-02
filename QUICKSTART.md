# Quick Start

## Prerequisites

- macOS or Linux machine on the same network as the targets
- Docker Desktop
- Python 3
- `p7zip` (`brew install p7zip` on macOS)
- `dnsmasq` (`brew install dnsmasq` on macOS)
- Viam CLI (`brew install viam` or binary download)

## One-time BIOS setup per target machine

Connect a monitor and keyboard. Enter BIOS setup (Del or F2 on System76 Meerkats).

1. **Enable PXE boot**: look for "UEFI PXE" under boot options
2. **Enable F12 network boot prompt**: check "Display F12 for network boot" if available
3. **Power restore**: set "Restore on AC Power Loss" to **Power On**
4. Save and exit

After provisioning, the installer sets boot order back to disk-first automatically.

## PXE server setup

```bash
# 1. Clone and enter the repo
git clone <repo-url> && cd viam-lab-provisioner

# 2. Python venv + Viam SDK
python3 -m venv .venv
.venv/bin/pip install viam-sdk

# 3. Extract GRUB, kernel, initrd, and ISO from Ubuntu installer
#    Downloads the ISO if not found locally (~3.2 GB)
./scripts/setup-pxe-server.sh

# 4. Add secrets to config/
cp config/viam-credentials.env.example config/viam-credentials.env
cp config/tailscale.key.example config/tailscale.key
cp ~/.ssh/id_ed25519.pub config/ssh_host_key.pub
#    Edit viam-credentials.env with your provisioning API key, org ID, location ID
#    Edit tailscale.key with your Tailscale auth key

# 5. Generate autoinstall config
./scripts/build-config.sh

# 6. Start services
just up     # HTTP server (Docker)
just dhcp   # proxy DHCP + TFTP (native dnsmasq, separate terminal)
```

## Provisioning a batch

```bash
# 1. Create machines in Viam and stage credentials
#    Using a config file:
./scripts/provision-batch.sh --config config/my-batch.env
#    Or with flags:
./scripts/provision-batch.sh \
    --count 6 \
    --prefix lab-meerkat \
    --org-id <your-org-id> \
    --location-id <your-location-id>

# 2. Start the PXE watcher (separate terminal)
just watch

# 3. Check status
just status

# 4. Power on machines one at a time (F12 for network boot)
#    The watcher prints name assignments:
#      [14:32:01] New PXE client: MAC aa:bb:cc:dd:ee:ff → assigned lab-meerkat-1
#      [14:32:18] New PXE client: MAC 11:22:33:44:55:66 → assigned lab-meerkat-2

# 5. Wait ~15 minutes per machine
#    Machines appear in app.viam.com and on Tailscale automatically.
```

## Provisioning Raspberry Pis

Pis use SD card flashing instead of PXE. The cloud provisioning step is the same.

```bash
# 1. Download Raspberry Pi OS Lite (64-bit) and place in the repo root
#    https://www.raspberrypi.com/software/operating-systems/
#    Save as pi-os.img (or leave as .img.xz — the script decompresses it)

# 2. Create machines in Viam (same as Meerkat batch)
./scripts/provision-batch.sh --config config/pi-batch.env

# 3. Flash each SD card
just flash /dev/disk4 lab-pi-1
just flash /dev/disk4 lab-pi-2
# ...

# 4. Insert cards, power on. First boot installs packages and configures
#    everything (~5 minutes). Machines appear in Viam + Tailscale.
```

## After provisioning

- **SSH**: `ssh viam@<hostname>` (password: `checkmate`, or use your SSH key)
- **Viam**: machines appear at app.viam.com under the provisioned names
- **Tailscale**: machines join your tailnet with their assigned hostnames
- **Re-provisioning**: F12 on boot to PXE boot again (boot order is disk-first after install)

## Batch config file format

Create `config/my-batch.env`:

```bash
COUNT=6
PREFIX=lab-meerkat
VIAM_API_KEY_ID=your-api-key-id
VIAM_API_KEY=your-api-key
VIAM_ORG_ID=your-org-id
VIAM_LOCATION_ID=your-location-id
```

## Commands

| Command | Description |
|---------|-------------|
| `just up` | Start HTTP server (Docker) |
| `just down` | Stop HTTP server |
| `just dhcp` | Start dnsmasq proxy DHCP + TFTP |
| `just watch` | Start PXE watcher (assigns names to MACs) |
| `just status` | Show queue state + service status |
| `just build-config` | Regenerate autoinstall user-data |
| `just setup` | Extract GRUB + kernel + initrd from Ubuntu ISO |
| `just provision <config>` | Create machines + stage credentials |
| `just flash <device> <name>` | Flash Pi SD card |
| `just reset` | Re-use current queue (mark unassigned) |
| `just clean` | Wipe all provisioning state |
