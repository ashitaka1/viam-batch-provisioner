#!/usr/bin/env bash
# Flash a USB stick that boots straight to the Viam autoinstaller, talking
# to a hardcoded provisioning host (instead of relying on PXE on the LAN).
#
# Each stick is unique: the target machine's hostname is baked into the
# kernel cmdline, and the provisioning host's IP:port is baked into the
# GRUB config. Two operators on the same network can run their own
# provisioning hosts without conflict — neither machine sees the other.
#
# Usage: flash-usb.sh <device> <machine-name> [--server IP:PORT]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETBOOT_DIR="${REPO_ROOT}/netboot"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
GRUB_TPL="${REPO_ROOT}/templates/usb-grub.cfg.tpl"
PICK_IFACE="${REPO_ROOT}/scripts/pick-server-iface.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 <device> <machine-name> [--server IP:PORT]

  device         USB block device (e.g., /dev/disk4 on macOS, /dev/sdb on Linux)
  machine-name   Hostname to bake into the stick (must match a queue entry in full mode)
  --server       Provisioning host as IP:PORT — defaults to auto-detected primary interface
EOF
    exit 1
}

[[ $# -ge 2 ]] || usage
DEVICE="$1"
MACHINE_NAME="$2"
shift 2

PXE_SERVER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server) PXE_SERVER="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# --- Load site config + verify boot files ---

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard'."
source "$SITE_CONFIG"
PROVISION_MODE="${PROVISION_MODE:-os-only}"
HTTP_PORT="${HTTP_PORT:-8234}"

[[ -f "${NETBOOT_DIR}/grubx64.efi" ]] || die "GRUB binary missing. Run 'just setup' first."
[[ -f "${NETBOOT_DIR}/vmlinuz" ]]    || die "vmlinuz missing. Run 'just setup' first."
[[ -f "${NETBOOT_DIR}/initrd" ]]     || die "initrd missing. Run 'just setup' first."
[[ -d "${NETBOOT_DIR}/grub/x86_64-efi" ]] || die "GRUB modules missing. Run 'just setup' first."

# --- Determine the provisioning host address ---

if [[ -z "$PXE_SERVER" ]]; then
    read -r IFACE IP < <("$PICK_IFACE")
    [[ -n "${IP:-}" ]] || die "Could not auto-detect a server IP. Pass --server IP:PORT."
    PXE_SERVER="${IP}:${HTTP_PORT}"
    echo "  Server: ${PXE_SERVER} (auto-detected via ${IFACE})"
else
    echo "  Server: ${PXE_SERVER}"
fi

# --- Validate machine name against queue (full mode only) ---

VIAM_JSON_FILE=""
if [[ "$PROVISION_MODE" == "full" ]]; then
    QUEUE_FILE="${MACHINES_DIR}/queue.json"
    [[ -f "$QUEUE_FILE" ]] || die "No queue.json. Run 'just provision' first."

    SLOT_ID=$(python3 -c "
import json, sys
q = json.load(open('$QUEUE_FILE'))
for s in q:
    if s['name'] == '$MACHINE_NAME':
        print(s.get('slot_id', ''))
        sys.exit(0)
print('')
")
    [[ -n "$SLOT_ID" ]] || die "Machine '$MACHINE_NAME' not found in queue.json"
    VIAM_JSON_FILE="${MACHINES_DIR}/${SLOT_ID}/viam.json"
    [[ -f "$VIAM_JSON_FILE" ]] || die "No viam.json staged for $MACHINE_NAME"
fi

# --- Validate the target device ---

[[ -b "$DEVICE" || -e "$DEVICE" ]] || die "Device $DEVICE does not exist"

OS="$(uname -s)"
echo ""
echo "=== Target Device ==="
if [[ "$OS" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / | awk '/Part of Whole:/ {print "/dev/" $NF}')
    [[ "$DEVICE" != "$BOOT_DISK" ]] || die "Refusing to write to boot disk $DEVICE"
    diskutil list "$DEVICE"
else
    ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || echo "")
    [[ "$DEVICE" != "/dev/$ROOT_DEV" ]] || die "Refusing to write to boot disk $DEVICE"
    lsblk "$DEVICE"
fi
echo ""

read -r -p "Wipe $DEVICE and write Viam install boot stick for '$MACHINE_NAME'? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted."

# --- Partition + format: GPT, single FAT32 ESP ---
# A single FAT32 ESP boots cleanly via the UEFI fallback path
# (\EFI\BOOT\BOOTX64.EFI), so the stick boots on any UEFI firmware
# without needing per-machine boot entries.

echo ""
echo "Partitioning $DEVICE (GPT, single FAT32 ESP)..."
if [[ "$OS" == "Darwin" ]]; then
    diskutil unmountDisk force "$DEVICE" >/dev/null
    # MS-DOS = FAT, GPT layout, volume label "VIAMBOOT"
    diskutil eraseDisk MS-DOS VIAMBOOT GPT "$DEVICE" >/dev/null
else
    sudo umount "${DEVICE}"* 2>/dev/null || true
    sudo wipefs -af "$DEVICE" >/dev/null
    sudo parted -s "$DEVICE" mklabel gpt
    sudo parted -s "$DEVICE" mkpart ESP fat32 1MiB 100%
    sudo parted -s "$DEVICE" set 1 esp on
    # Wait for the kernel to expose the new partition
    sudo partprobe "$DEVICE" || true
    sleep 1
    PART="${DEVICE}1"
    [[ -b "${DEVICE}p1" ]] && PART="${DEVICE}p1"
    sudo mkfs.vfat -F32 -n VIAMBOOT "$PART" >/dev/null
fi

# --- Mount the boot partition ---

echo "Mounting boot partition..."
if [[ "$OS" == "Darwin" ]]; then
    # eraseDisk leaves it mounted at /Volumes/VIAMBOOT
    BOOT_MOUNT="/Volumes/VIAMBOOT"
    [[ -d "$BOOT_MOUNT" ]] || die "Volume not mounted at $BOOT_MOUNT"
else
    PART="${DEVICE}1"
    [[ -b "${DEVICE}p1" ]] && PART="${DEVICE}p1"
    BOOT_MOUNT=$(mktemp -d)
    sudo mount "$PART" "$BOOT_MOUNT"
fi
echo "  Mounted at: $BOOT_MOUNT"

# Helper that respects sudo on Linux
sh_run() {
    if [[ "$OS" == "Darwin" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# --- Lay out the boot stick ---
# Layout (FAT32, ~270 MB):
#   /EFI/BOOT/BOOTX64.EFI          -- GRUB EFI binary (UEFI fallback path)
#   /vmlinuz, /initrd              -- Ubuntu installer kernel + initramfs
#   /grub/grub.cfg                 -- per-stick: server IP + machine name
#   /grub/x86_64-efi/*.mod         -- GRUB modules (linux, http, etc.)
#   /MACHINE.txt                   -- human-readable label for stick swaps

echo "Copying GRUB + kernel + initrd..."
sh_run mkdir -p "${BOOT_MOUNT}/EFI/BOOT" "${BOOT_MOUNT}/grub"
sh_run cp "${NETBOOT_DIR}/grubx64.efi" "${BOOT_MOUNT}/EFI/BOOT/BOOTX64.EFI"
sh_run cp "${NETBOOT_DIR}/vmlinuz"     "${BOOT_MOUNT}/vmlinuz"
sh_run cp "${NETBOOT_DIR}/initrd"      "${BOOT_MOUNT}/initrd"
sh_run cp -R "${NETBOOT_DIR}/grub/x86_64-efi" "${BOOT_MOUNT}/grub/x86_64-efi"

echo "Writing per-stick grub.cfg..."
TMP_GRUB=$(mktemp)
PXE_SERVER="$PXE_SERVER" MACHINE_NAME="$MACHINE_NAME" \
    envsubst '${PXE_SERVER} ${MACHINE_NAME}' < "$GRUB_TPL" > "$TMP_GRUB"
sh_run cp "$TMP_GRUB" "${BOOT_MOUNT}/grub/grub.cfg"
rm -f "$TMP_GRUB"

# Drop a label file so an operator can ID the stick after the fact
LABEL_TMP=$(mktemp)
cat > "$LABEL_TMP" <<EOF
Viam provisioning boot stick

  Hostname: ${MACHINE_NAME}
  Server:   http://${PXE_SERVER}/
  Mode:     ${PROVISION_MODE}
  Built:    $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Boot the target machine from this stick (UEFI). It will install
Ubuntu, set its hostname, and (in full mode) fetch its Viam
credentials from the server above.
EOF
sh_run cp "$LABEL_TMP" "${BOOT_MOUNT}/MACHINE.txt"
rm -f "$LABEL_TMP"

# --- Stage per-name credentials on the HTTP server (full mode) ---
# In USB mode the installer fetches viam.json by hostname (no MAC
# watcher to assign per-MAC paths), so stage it under by-name/.

if [[ -n "$VIAM_JSON_FILE" ]]; then
    echo "Staging credentials at machines/by-name/${MACHINE_NAME}/viam.json..."
    BY_NAME_DIR="${MACHINES_DIR}/by-name/${MACHINE_NAME}"
    mkdir -p "$BY_NAME_DIR"
    cp "$VIAM_JSON_FILE" "${BY_NAME_DIR}/viam.json"
fi

# --- Mark slot assigned in queue (USB mode has no MAC) ---

QUEUE_FILE="${MACHINES_DIR}/queue.json"
if [[ -f "$QUEUE_FILE" ]]; then
    python3 - "$QUEUE_FILE" "$MACHINE_NAME" <<'PY'
import json, sys
qf, name = sys.argv[1], sys.argv[2]
q = json.load(open(qf))
for s in q:
    if s["name"] == name:
        s["assigned"] = True
        s["flashed_via"] = "usb"
        break
json.dump(q, open(qf, "w"), indent=2)
PY
fi

# --- Unmount ---

echo "Unmounting..."
if [[ "$OS" == "Darwin" ]]; then
    diskutil unmountDisk "$DEVICE" >/dev/null
else
    sudo umount "$BOOT_MOUNT"
    rmdir "$BOOT_MOUNT"
fi

cat <<EOF

=== USB Boot Stick Ready ===
  Hostname: ${MACHINE_NAME}
  Server:   ${PXE_SERVER}
  Mode:     ${PROVISION_MODE}
  Device:   ${DEVICE}

Label this stick '${MACHINE_NAME}', plug it into the target machine,
and boot from USB (UEFI). Make sure 'just serve-usb' is running on
this host so the target can fetch the ISO and autoinstall config.
EOF
