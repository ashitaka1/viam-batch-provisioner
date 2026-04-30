#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
USERDATA_TPL="${REPO_ROOT}/templates/pi-user-data.tpl"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 <device> <machine-name>

  device        Block device for the SD card (e.g., /dev/disk4 on macOS, /dev/sdb on Linux)
  machine-name  Machine name (from provision-batch.sh queue, or any name in os-only mode)

Example:
  $0 /dev/disk4 lab-pi-1
EOF
    exit 1
}

[[ $# -eq 2 ]] || usage
DEVICE="$1"
MACHINE_NAME="$2"

# --- Load site config ---

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard' to create it."
source "$SITE_CONFIG"

SSH_PUBLIC_KEY=$(cat "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}" 2>/dev/null) \
    || die "SSH public key not found at ${SSH_PUBLIC_KEY_FILE}"

PASSWORD_HASH=$(echo "$PASSWORD" | mkpasswd -m sha-512 --stdin 2>/dev/null) \
    || PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")

# --- Find the machine's credentials (full mode only) ---

VIAM_JSON_FILE=""
if [[ "$PROVISION_MODE" == "full" ]]; then
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
    VIAM_JSON_FILE="${MACHINES_DIR}/${SLOT_ID}/viam.json"
    [[ -f "$VIAM_JSON_FILE" ]] || die "No viam.json found in ${MACHINES_DIR}/${SLOT_ID}"
fi

# --- Locate the base image ---

PI_IMAGE=""
for f in "${REPO_ROOT}"/pi-os.img "${REPO_ROOT}"/*raspios*.img; do
    if [[ -f "$f" ]]; then
        PI_IMAGE="$f"
        break
    fi
done
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
[[ -n "$PI_IMAGE" ]] || die "No Pi OS image found. Run 'just download-pi-image' or place a .img/.img.xz in the repo root."

# --- Validate the target device ---

[[ -e "$DEVICE" ]] || die "Device $DEVICE does not exist"

if [[ "$(uname)" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / | awk '/Part of Whole:/ {print "/dev/" $NF}')
    [[ "$DEVICE" != "$BOOT_DISK" ]] || die "Refusing to write to boot disk $DEVICE"
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
    diskutil unmountDisk "$DEVICE"
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
    BOOT_MOUNT=$(mount | grep "${DEVICE}" | grep -i 'msdos\|fat' | awk '{print $3}' | head -1)
    if [[ -z "$BOOT_MOUNT" ]]; then
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

# --- Build conditional blocks for template ---

INSTALL_VIAM="false"
[[ "$PROVISION_MODE" == "full" || "$PROVISION_MODE" == "agent" ]] && INSTALL_VIAM="true"

INSTALL_TAILSCALE="false"
[[ -n "${TAILSCALE_AUTH_KEY:-}" ]] && INSTALL_TAILSCALE="true"

# Read the active env's package list. Same source of truth as build-config.sh.
# Comments (#) and blank lines are stripped; remaining lines are joined with
# spaces for the apt-get install argv on the target.
[[ -L "$SITE_CONFIG" ]] || die "$SITE_CONFIG must be a symlink (created by setup-wizard)"
ENV_NAME=$(basename "$(readlink "$SITE_CONFIG")" .env)
PACKAGES_FILE="${REPO_ROOT}/config/environments/${ENV_NAME}.packages.txt"
PACKAGES_EXAMPLE="${REPO_ROOT}/config/packages.txt.example"
if [[ ! -f "$PACKAGES_FILE" && -f "$PACKAGES_EXAMPLE" ]]; then
    cp "$PACKAGES_EXAMPLE" "$PACKAGES_FILE"
    echo "  Seeded $(basename "$PACKAGES_FILE") from packages.txt.example"
fi
PACKAGES=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print $1}' "$PACKAGES_FILE" | tr '\n' ' ')

# --- Generate cloud-init user-data ---

echo "Writing cloud-init config..."
python3 -c "
import sys
template = open(sys.argv[1]).read()
template = template.replace('PLACEHOLDER_HOSTNAME', sys.argv[2])
template = template.replace('PLACEHOLDER_PASSWORD_HASH', sys.argv[3])
template = template.replace('PLACEHOLDER_SSH_KEY', sys.argv[4])
template = template.replace('PLACEHOLDER_USERNAME', sys.argv[5])
template = template.replace('PLACEHOLDER_TIMEZONE', sys.argv[6])
template = template.replace('PLACEHOLDER_INSTALL_VIAM', sys.argv[7])
template = template.replace('PLACEHOLDER_INSTALL_TAILSCALE', sys.argv[8])
template = template.replace('PLACEHOLDER_PACKAGES', sys.argv[9])
open(sys.argv[10], 'w').write(template)
" "$USERDATA_TPL" "$MACHINE_NAME" "$PASSWORD_HASH" "$SSH_PUBLIC_KEY" \
  "$USERNAME" "$TIMEZONE" "$INSTALL_VIAM" "$INSTALL_TAILSCALE" "$PACKAGES" \
  "${BOOT_MOUNT}/user-data"

# --- Write viam.json (full mode only) ---

if [[ -n "$VIAM_JSON_FILE" ]]; then
    cp "$VIAM_JSON_FILE" "${BOOT_MOUNT}/viam.json"
fi

# --- Write Tailscale key ---

if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    echo "$TAILSCALE_AUTH_KEY" > "${BOOT_MOUNT}/tailscale-authkey"
fi

# --- Write network config ---

echo "Writing network config..."
if [[ -n "${WIFI_SSID:-}" ]]; then
    cat > "${BOOT_MOUNT}/network-config" <<NETEOF
network:
  version: 2

  ethernets:
    eth0:
      dhcp4: true
      optional: true

  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "${WIFI_SSID}":
          password: "${WIFI_PASSWORD}"
NETEOF
else
    cat > "${BOOT_MOUNT}/network-config" <<NETEOF
network:
  version: 2

  ethernets:
    eth0:
      dhcp4: true
      optional: true
NETEOF
fi

# --- Write meta-data ---

cat > "${BOOT_MOUNT}/meta-data" <<META
instance_id: $(date +%s)-${MACHINE_NAME}
META

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
echo "  Machine:  ${MACHINE_NAME}"
echo "  Mode:     ${PROVISION_MODE}"
echo "  Image:    $(basename $PI_IMAGE)"
echo "  Device:   ${DEVICE}"
[[ -n "${WIFI_SSID:-}" ]] && echo "  WiFi:     ${WIFI_SSID}"
[[ -n "${TAILSCALE_AUTH_KEY:-}" ]] && echo "  Tailscale: yes"
echo ""
echo "Insert into Pi and power on."
