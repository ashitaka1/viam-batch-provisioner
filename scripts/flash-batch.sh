#!/usr/bin/env bash
# Walk the queue and flash one Pi SD card per unassigned machine.
# Pi cards are self-contained after flashing — no HTTP/DHCP server needed,
# since Phase 2 cloud-init pulls Viam + Tailscale directly from public URLs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FLASH_SCRIPT="${REPO_ROOT}/scripts/flash-pi-sd.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard'."
source "$SITE_CONFIG"
PROVISION_MODE="${PROVISION_MODE:-os-only}"

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

echo "=== Batch SD Card Flashing ==="
echo "  Cards to flash: ${TOTAL}"
echo "  Mode:           ${PROVISION_MODE}"
echo ""

# --- Detect the freshly-inserted SD card ---
# All operator-facing output goes to stderr (>&2) and reads come from /dev/tty,
# because this function is called via $(detect_sd_card) — anything on stdout
# is captured into the substitution buffer, not shown to the operator.

detect_sd_card() {
    local OS
    OS="$(uname -s)"

    if [[ "$OS" == "Darwin" ]]; then
        local BEFORE
        BEFORE=$(diskutil list | grep '^/dev/disk' | awk '{print $1}')
        echo "  Insert SD card now, then press Enter..." >&2
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
        echo "  Insert SD card now, then press Enter..." >&2
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
    DEVICE=$(detect_sd_card)

    if [[ -z "$DEVICE" ]]; then
        echo "  Skipping ${NAME} (no device)."
        continue
    fi

    "$FLASH_SCRIPT" "$DEVICE" "$NAME"
    FLASHED=$((FLASHED + 1))

    echo ""
    if [[ $NUM -lt $TOTAL ]]; then
        echo "  Remove the card and label it '${NAME}'."
        read -r -p "  Continue to next? (Enter = yes, q = quit): " CONT </dev/tty
        [[ "$CONT" != "q" ]] || break
        echo ""
    else
        echo "  Remove the card and label it '${NAME}'."
    fi
done

cat <<EOF

=== Done ===
  Flashed: ${FLASHED} of ${TOTAL}

Next:
  Insert each card into its labeled Pi and power on.
  Phase 2 cloud-init runs on first boot — give it a few minutes for
  packages, viam-agent, and Tailscale to install.
EOF
