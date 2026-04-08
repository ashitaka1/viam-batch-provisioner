#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FLASH_SCRIPT="${REPO_ROOT}/scripts/flash-pi-sd.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard'."
source "$SITE_CONFIG"

# --- Build the list of machines to flash ---

NAMES=()
QUEUE_FILE="${MACHINES_DIR}/queue.json"

if [[ -f "$QUEUE_FILE" ]]; then
    # Read names from queue (may be from full or os-only provisioning)
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
    # No queue — generate names from PREFIX + COUNT
    [[ -n "${PREFIX:-}" ]] || die "No queue.json and no PREFIX in config"
    [[ -n "${COUNT:-}" ]] || die "No queue.json and no COUNT in config"
    for i in $(seq 1 "$COUNT"); do
        NAMES+=("${PREFIX}-${i}")
    done
fi

TOTAL=${#NAMES[@]}
[[ "$TOTAL" -gt 0 ]] || die "No machines to flash. Run 'just provision' first."

echo "=== Batch SD Card Flashing ==="
echo "  Machines: ${TOTAL}"
echo "  Mode: ${PROVISION_MODE:-os-only}"
echo ""

# --- macOS SD card auto-detection ---

detect_sd_card() {
    if [[ "$(uname)" != "Darwin" ]]; then
        read -p "  Device (e.g., /dev/sdb): " DETECTED_DEVICE
        echo "$DETECTED_DEVICE"
        return
    fi

    # Snapshot current disks
    local BEFORE=$(diskutil list | grep '^/dev/disk' | awk '{print $1}')

    echo "  Insert SD card now, then press Enter..."
    read -r

    sleep 2
    local AFTER=$(diskutil list | grep '^/dev/disk' | awk '{print $1}')

    # Find the new disk
    local NEW_DISK=""
    for disk in $AFTER; do
        if ! echo "$BEFORE" | grep -q "^${disk}$"; then
            NEW_DISK="$disk"
            break
        fi
    done

    if [[ -n "$NEW_DISK" ]]; then
        echo "  Detected: ${NEW_DISK}"
        echo "$NEW_DISK"
    else
        echo "  Could not auto-detect SD card."
        read -p "  Device (e.g., /dev/disk4): " DETECTED_DEVICE
        echo "$DETECTED_DEVICE"
    fi
}

# --- Flash loop ---

FLASHED=0
for i in "${!NAMES[@]}"; do
    NAME="${NAMES[$i]}"
    NUM=$((i + 1))

    echo "=== ${NUM} of ${TOTAL}: ${NAME} ==="
    echo ""

    # Detect or prompt for device
    DEVICE=$(detect_sd_card)

    if [[ -z "$DEVICE" ]]; then
        echo "  Skipping ${NAME} (no device)"
        continue
    fi

    # Flash
    "$FLASH_SCRIPT" "$DEVICE" "$NAME"
    FLASHED=$((FLASHED + 1))

    echo ""
    if [[ $NUM -lt $TOTAL ]]; then
        echo "  Remove SD card and label it '${NAME}'."
        echo ""
        read -p "  Continue to next? (Enter = yes, q = quit): " CONTINUE
        [[ "$CONTINUE" != "q" ]] || break
        echo ""
    else
        echo "  Remove SD card and label it '${NAME}'."
    fi
done

echo ""
echo "=== Done ==="
echo "  Flashed: ${FLASHED} of ${TOTAL}"
echo "  Insert cards into Pis and power on."
