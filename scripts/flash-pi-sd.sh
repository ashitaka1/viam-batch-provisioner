#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
CONFIG_DIR="${REPO_ROOT}/config"
TEMPLATE="${REPO_ROOT}/templates/pi-firstboot.sh.tpl"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 <device> <machine-name>

  device        Block device for the SD card (e.g., /dev/disk4 on macOS, /dev/sdb on Linux)
  machine-name  Name of a machine already created by provision-batch.sh

The machine-name must have a matching slot in http-server/machines/ with viam.json.

Example:
  $0 /dev/disk4 lab-pi-1
EOF
    exit 1
}

[[ $# -eq 2 ]] || usage
DEVICE="$1"
MACHINE_NAME="$2"

# --- Find the machine's credentials ---

SLOT_DIR=""
QUEUE_FILE="${MACHINES_DIR}/queue.json"
[[ -f "$QUEUE_FILE" ]] || die "No queue.json found. Run provision-batch.sh first."

SLOT_ID=$(python3 -c "
import json, sys
q = json.load(open('$QUEUE_FILE'))
for s in q:
    if s['name'] == '$MACHINE_NAME':
        print(s['slot_id'])
        sys.exit(0)
print('')
")

[[ -n "$SLOT_ID" ]] || die "Machine '$MACHINE_NAME' not found in queue.json"
SLOT_DIR="${MACHINES_DIR}/${SLOT_ID}"
[[ -f "${SLOT_DIR}/viam.json" ]] || die "No viam.json found in ${SLOT_DIR}"

# --- Locate the base image ---

PI_IMAGE=""
# Look for an uncompressed image first
for f in "${REPO_ROOT}"/pi-os.img "${REPO_ROOT}"/*raspios*.img; do
    if [[ -f "$f" ]]; then
        PI_IMAGE="$f"
        break
    fi
done
# Fall back to compressed images
if [[ -z "$PI_IMAGE" ]]; then
    for f in "${REPO_ROOT}"/pi-os.img.xz "${REPO_ROOT}"/*raspios*.img.xz; do
        if [[ -f "$f" ]]; then
            echo "Decompressing $(basename $f)..."
            xz -dk "$f"
            PI_IMAGE="${f%.xz}"
            break
        fi
    done
fi
[[ -f "$PI_IMAGE" ]] || die "No Pi OS image found. Download Raspberry Pi OS Lite (64-bit) and place as pi-os.img or *.img.xz in the repo root."

# --- Validate the target device ---

[[ -e "$DEVICE" ]] || die "Device $DEVICE does not exist"

# Safety: refuse to write to the boot disk
if [[ "$(uname)" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / | awk '/Part of Whole:/ {print "/dev/" $NF}')
    [[ "$DEVICE" != "$BOOT_DISK" ]] || die "Refusing to write to boot disk $DEVICE"
    # Show disk info for confirmation
    echo "=== Target Device ==="
    diskutil list "$DEVICE"
else
    ROOT_DEV=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || echo "")
    [[ "$DEVICE" != "/dev/$ROOT_DEV" ]] || die "Refusing to write to boot disk $DEVICE"
    echo "=== Target Device ==="
    lsblk "$DEVICE"
fi

echo ""
read -p "Write $(basename $PI_IMAGE) to $DEVICE? This will ERASE ALL DATA. (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted."

# --- Write the image ---

echo "Writing image to $DEVICE..."
if [[ "$(uname)" == "Darwin" ]]; then
    # Unmount all partitions on the device
    diskutil unmountDisk "$DEVICE"
    # Use raw device for speed
    RAW_DEVICE="${DEVICE/disk/rdisk}"
    sudo dd if="$PI_IMAGE" of="$RAW_DEVICE" bs=4m status=progress
    sleep 2
else
    sudo dd if="$PI_IMAGE" of="$DEVICE" bs=4M status=progress conv=fsync
    sleep 2
fi

# --- Mount the boot partition ---

echo "Mounting boot partition..."
if [[ "$(uname)" == "Darwin" ]]; then
    diskutil mountDisk "$DEVICE"
    sleep 2
    # Find the FAT32 boot partition mount point
    BOOT_MOUNT=$(mount | grep "${DEVICE}" | grep -i 'msdos\|fat' | awk '{print $3}' | head -1)
    if [[ -z "$BOOT_MOUNT" ]]; then
        # Try the common name
        BOOT_MOUNT="/Volumes/bootfs"
        [[ -d "$BOOT_MOUNT" ]] || BOOT_MOUNT="/Volumes/boot"
    fi
else
    BOOT_PART="${DEVICE}1"
    [[ -b "${DEVICE}p1" ]] && BOOT_PART="${DEVICE}p1"
    BOOT_MOUNT=$(mktemp -d)
    sudo mount "$BOOT_PART" "$BOOT_MOUNT"
fi

[[ -d "$BOOT_MOUNT" ]] || die "Could not find boot partition mount at $BOOT_MOUNT"
echo "  Boot partition mounted at: $BOOT_MOUNT"

# --- Load secrets ---

[[ -f "${CONFIG_DIR}/ssh_host_key.pub" ]] || die "Missing config/ssh_host_key.pub"
SSH_KEY=$(cat "${CONFIG_DIR}/ssh_host_key.pub")

PASSWORD_HASH=$(echo 'checkmate' | mkpasswd -m sha-512 --stdin 2>/dev/null) \
    || PASSWORD_HASH=$(openssl passwd -6 'checkmate')

# --- Generate and write firstrun.sh ---

echo "Writing first-boot config..."
python3 -c "
import sys
template = open(sys.argv[1]).read()
template = template.replace('PLACEHOLDER_HOSTNAME', sys.argv[2])
template = template.replace('PLACEHOLDER_PASSWORD_HASH', sys.argv[3])
template = template.replace('PLACEHOLDER_SSH_KEY', sys.argv[4])
open(sys.argv[5], 'w').write(template)
" "$TEMPLATE" "$MACHINE_NAME" "$PASSWORD_HASH" "$SSH_KEY" "${BOOT_MOUNT}/firstrun.sh"
chmod 755 "${BOOT_MOUNT}/firstrun.sh"

# --- Write viam.json to boot partition ---

cp "${SLOT_DIR}/viam.json" "${BOOT_MOUNT}/viam.json"

# --- Write Tailscale key to boot partition ---

if [[ -f "${CONFIG_DIR}/tailscale.key" ]]; then
    grep -v '^#' "${CONFIG_DIR}/tailscale.key" | tr -d '[:space:]' > "${BOOT_MOUNT}/tailscale.key"
fi

# --- Enable SSH ---

touch "${BOOT_MOUNT}/ssh"

# --- Wire firstrun.sh into cmdline.txt ---
# Pi OS Bookworm+ mounts boot at /boot/firmware, older at /boot
# The firstrun.sh path in cmdline.txt must match the on-Pi mount point

CMDLINE="${BOOT_MOUNT}/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
    if ! grep -q 'systemd.run=' "$CMDLINE"; then
        # Use /boot/firmware path for Bookworm+
        sed -i.bak 's/$/ systemd.run=\/boot\/firmware\/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target/' "$CMDLINE"
        rm -f "${CMDLINE}.bak"
    fi
else
    echo "WARNING: cmdline.txt not found at ${CMDLINE}" >&2
fi

# --- Unmount ---

echo "Unmounting..."
if [[ "$(uname)" == "Darwin" ]]; then
    diskutil unmountDisk "$DEVICE"
else
    sudo umount "$BOOT_MOUNT"
    rmdir "$BOOT_MOUNT"
fi

echo ""
echo "=== SD Card Ready ==="
echo "  Machine: ${MACHINE_NAME}"
echo "  Image:   $(basename $PI_IMAGE)"
echo "  Device:  ${DEVICE}"
echo ""
echo "Insert into Pi and power on. First boot will take a few minutes"
echo "while packages install and services configure."
