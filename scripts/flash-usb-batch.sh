#!/usr/bin/env bash
# Walk the queue and flash one USB stick per unassigned machine.
# Asks for the provisioning host's interface up front (so every stick
# in the batch points at the same address), then guides the operator
# through plugging in, identifying, confirming, and writing each stick.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FLASH_SCRIPT="${REPO_ROOT}/scripts/flash-usb.sh"
PICK_IFACE="${REPO_ROOT}/scripts/pick-server-iface.sh"
SERVER_FILE="${REPO_ROOT}/config/.server-address"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard'."
source "$SITE_CONFIG"
HTTP_PORT="${HTTP_PORT:-8234}"
PROVISION_MODE="${PROVISION_MODE:-os-only}"

# --- Pick the provisioning host interface (once per batch) ---

echo "=== Provisioning host network interface ==="
echo "Target machines must reach this host on the chosen interface."
read -r IFACE IP < <("$PICK_IFACE" --interactive)
[[ -n "${IP:-}" ]] || die "No interface chosen."
PXE_SERVER="${IP}:${HTTP_PORT}"

# Persist for `just serve-usb`, so build-config.sh stamps the same
# address into user-data that's baked into each stick.
mkdir -p "$(dirname "$SERVER_FILE")"
echo "$PXE_SERVER" > "$SERVER_FILE"

echo ""
echo "  Server:    ${PXE_SERVER}"
echo "  Interface: ${IFACE}"
echo ""

# --- Build the list of machines to flash ---

NAMES=()
QUEUE_FILE="${MACHINES_DIR}/queue.json"

if [[ -f "$QUEUE_FILE" ]]; then
    while IFS= read -r name; do
        NAMES+=("$name")
    done < <(python3 -c "
import json
q = json.load(open('$QUEUE_FILE'))
for s in q:
    if not s.get('assigned'):
        print(s['name'])
")
else
    [[ -n "${PREFIX:-}" && -n "${COUNT:-}" ]] || \
        die "No queue.json. Run 'just provision' first."
    for i in $(seq 1 "$COUNT"); do
        NAMES+=("${PREFIX}-${i}")
    done
fi

TOTAL=${#NAMES[@]}
[[ "$TOTAL" -gt 0 ]] || die "No machines to flash. Run 'just provision' first."

echo "=== Batch USB Flashing ==="
echo "  Sticks to flash: ${TOTAL}"
echo "  Mode:            ${PROVISION_MODE}"
echo ""

# --- Detect the freshly-inserted USB device ---
# Same trick as flash-batch.sh's SD-card detection: snapshot the disk
# list, prompt the operator to plug in, then diff.

detect_usb() {
    local OS
    OS="$(uname -s)"

    if [[ "$OS" == "Darwin" ]]; then
        local BEFORE
        BEFORE=$(diskutil list | grep '^/dev/disk' | awk '{print $1}')
        echo "  Plug in the USB stick now, then press Enter..." >&2
        read -r </dev/tty
        sleep 2
        local AFTER
        AFTER=$(diskutil list | grep '^/dev/disk' | awk '{print $1}')
        local NEW=""
        for d in $AFTER; do
            grep -qx "$d" <<< "$BEFORE" || NEW="$d"
        done
        if [[ -n "$NEW" ]]; then
            echo "  Detected: $NEW" >&2
            echo "$NEW"
        else
            echo "  Could not auto-detect. Enter device manually." >&2
            read -r -p "  Device (e.g., /dev/disk4): " DEV </dev/tty
            echo "$DEV"
        fi
    else
        local BEFORE AFTER
        BEFORE=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
        echo "  Plug in the USB stick now, then press Enter..." >&2
        read -r </dev/tty
        sleep 2
        AFTER=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
        local NEW=""
        for d in $AFTER; do
            grep -qx "$d" <<< "$BEFORE" || NEW="$d"
        done
        if [[ -n "$NEW" ]]; then
            echo "  Detected: $NEW" >&2
            echo "$NEW"
        else
            echo "  Could not auto-detect. Enter device manually." >&2
            read -r -p "  Device (e.g., /dev/sdb): " DEV </dev/tty
            echo "$DEV"
        fi
    fi
}

# --- Flash loop ---

FLASHED=0
for i in "${!NAMES[@]}"; do
    NAME="${NAMES[$i]}"
    NUM=$((i + 1))

    echo "=== ${NUM} of ${TOTAL}: ${NAME} ==="
    DEVICE=$(detect_usb)

    if [[ -z "$DEVICE" ]]; then
        echo "  Skipping ${NAME} (no device)."
        continue
    fi

    "$FLASH_SCRIPT" "$DEVICE" "$NAME" --server "$PXE_SERVER"
    FLASHED=$((FLASHED + 1))

    echo ""
    if [[ $NUM -lt $TOTAL ]]; then
        echo "  Remove the stick and label it '${NAME}'."
        read -r -p "  Continue to next? (Enter = yes, q = quit): " CONT </dev/tty
        [[ "$CONT" != "q" ]] || break
        echo ""
    else
        echo "  Remove the stick and label it '${NAME}'."
    fi
done

cat <<EOF

=== Done ===
  Flashed: ${FLASHED} of ${TOTAL}
  Server:  ${PXE_SERVER}

Next:
  just serve-usb       # start HTTP server (no DHCP/TFTP needed)
  Then plug each stick into its target machine and boot from USB.
EOF
