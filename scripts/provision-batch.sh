#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FETCH_CREDS="${REPO_ROOT}/scripts/fetch-credentials.py"
PYTHON="${REPO_ROOT}/.venv/bin/python3"
QUEUE_STORE="${REPO_ROOT}/pxe-watcher/queue_store.py"
SITE_CONFIG="${REPO_ROOT}/config/site.env"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Parse arguments ---

BATCH_CONFIG=""
CLI_COUNT=""
CLI_PREFIX=""
CLI_LOCATION=""
CLI_ORG=""

usage() {
    cat <<EOF
Usage: $0 --prefix PREFIX --count N [--config FILE] [--location-id ID] [--org-id ID]

  --prefix PREFIX    Name prefix (e.g., lab-pi, teleop-demo)
  --count N          Number of machines
  --config FILE      Environment config (default: config/site.env)
  --location-id ID   Override Viam location ID from config
  --org-id ID        Override Viam org ID from config

Environment settings (credentials, WiFi, etc.) come from config/site.env.
Run 'just setup-wizard' to create or switch environments.

In os-only/agent mode, generates a names-only queue for SD card flashing.
In full mode, creates machines in Viam and retrieves cloud credentials.
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)      BATCH_CONFIG="$2"; shift 2 ;;
        --count)       CLI_COUNT="$2"; shift 2 ;;
        --prefix)      CLI_PREFIX="$2"; shift 2 ;;
        --location-id) CLI_LOCATION="$2"; shift 2 ;;
        --org-id)      CLI_ORG="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             die "Unknown argument: $1" ;;
    esac
done

# --- Load config ---

CONFIG_FILE="${BATCH_CONFIG:-$SITE_CONFIG}"
[[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE. Run 'just setup-wizard' to create config/site.env."
source "$CONFIG_FILE"

COUNT="${CLI_COUNT:-${COUNT:-}}"
PREFIX="${CLI_PREFIX:-${PREFIX:-}}"
PROVISION_MODE="${PROVISION_MODE:-os-only}"

[[ -n "$COUNT" ]]  || die "--count or COUNT in config is required"
[[ -n "$PREFIX" ]] || die "--prefix or PREFIX in config is required"

# --- Existing queue: new machines are appended ---

mkdir -p "$MACHINES_DIR"
QUEUE_FILE="${MACHINES_DIR}/queue.json"
if [[ -f "$QUEUE_FILE" ]]; then
    read -r UNASSIGNED TOTAL < <(python3 "$QUEUE_STORE" summary --queue-dir "$MACHINES_DIR")
    echo "Existing queue: ${UNASSIGNED} waiting / ${TOTAL} total — new machines will be appended ('just clean' to start over)."
    echo ""
fi

# --- OS-only / agent mode: just generate names ---

if [[ "$PROVISION_MODE" != "full" ]]; then
    echo "Mode: ${PROVISION_MODE} (no Viam cloud provisioning)"
    echo ""

    START=$(python3 "$QUEUE_STORE" next-index --prefix "$PREFIX" --queue-dir "$MACHINES_DIR")
    END=$((START + COUNT - 1))
    ENTRIES=$(python3 -c "
import json, sys
prefix, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
json.dump([{'name': f'{prefix}-{i}', 'assigned': False} for i in range(start, end + 1)], sys.stdout)
" "$PREFIX" "$START" "$END")
    python3 "$QUEUE_STORE" append --queue-dir "$MACHINES_DIR" <<< "$ENTRIES"

    echo ""
    echo "=== Queue Ready ==="
    echo "  Added: ${COUNT} (${PREFIX}-${START} through ${PREFIX}-${END})"
    echo "  Queue file: ${QUEUE_FILE}"
    echo ""
    echo "Next:"
    echo "  Pi SD card:  just flash-batch"
    echo "  x86 PXE:     just serve        (or just serve-daemon for an always-on server)"
    echo "  x86 USB:     just flash-usb-batch && just serve-usb"
    exit 0
fi

# --- Full mode: create machines in Viam ---

ORG="${CLI_ORG:-${VIAM_ORG_ID:-}}"
LOCATION="${CLI_LOCATION:-${VIAM_LOCATION_ID:-}}"
[[ -n "$ORG" ]]      || die "VIAM_ORG_ID required for full provisioning"
[[ -n "$LOCATION" ]] || die "VIAM_LOCATION_ID required for full provisioning"
[[ -n "${VIAM_API_KEY_ID:-}" ]] || die "VIAM_API_KEY_ID required for full provisioning"
[[ -n "${VIAM_API_KEY:-}" ]]    || die "VIAM_API_KEY required for full provisioning"
export VIAM_API_KEY_ID VIAM_API_KEY

# Check dependencies
command -v viam &>/dev/null || die "viam CLI not found. Install from https://docs.viam.com/dev/tools/cli/"
[[ -x "$PYTHON" ]] || die "Python venv not found. Re-run 'just setup-wizard' or set up manually: python3 -m venv .venv && .venv/bin/pip install viam-sdk"
"$PYTHON" -c "import viam" 2>/dev/null || die "viam-sdk not installed. Run: .venv/bin/pip install viam-sdk"

echo "Authenticating with Viam..."
viam login api-key --key-id="$VIAM_API_KEY_ID" --key="$VIAM_API_KEY"

# Resolve org + location names so the operator knows where machines will land
LABELS=$("$PYTHON" "${REPO_ROOT}/scripts/resolve-labels.py" --org-id="$ORG" --location-id="$LOCATION" 2>/dev/null || true)
ORG_NAME=$(echo "$LABELS" | sed -n 's/^ORG_NAME=//p')
LOC_NAME=$(echo "$LABELS" | sed -n 's/^LOCATION_NAME=//p')
echo ""

# Find available machine numbers (fills gaps first)
echo "Listing existing machines with prefix '${PREFIX}'..."
EXISTING=$(viam machines list --organization="$ORG" --location="$LOCATION" 2>/dev/null || true)

EXISTING_NUMS=()
while IFS= read -r line; do
    if [[ "$line" =~ ${PREFIX}-([0-9]+) ]]; then
        EXISTING_NUMS+=("$((10#${BASH_REMATCH[1]}))")
    fi
done <<< "$EXISTING"

AVAILABLE=()
HIGHEST=0
for n in "${EXISTING_NUMS[@]:-}"; do
    (( n > HIGHEST )) && HIGHEST=$n
done

for (( n=1; n<=HIGHEST; n++ )); do
    FOUND=0
    for e in "${EXISTING_NUMS[@]:-}"; do
        [[ "$e" -eq "$n" ]] && FOUND=1 && break
    done
    [[ "$FOUND" -eq 0 ]] && AVAILABLE+=("$n")
done

# A number is taken if it is already queued locally, even when Viam has no
# machine for it (a stale slot from a failed run).
number_taken() {
    python3 "$QUEUE_STORE" has-name --name "${PREFIX}-$1" --queue-dir "$MACHINES_DIR" \
        || [[ -d "${MACHINES_DIR}/slot-${PREFIX}-$1" ]]
}

FILTERED=()
for n in "${AVAILABLE[@]:-}"; do
    [[ -n "$n" ]] || continue
    if number_taken "$n"; then
        echo "  skip ${PREFIX}-${n}: already in queue"
    else
        FILTERED+=("$n")
    fi
done
AVAILABLE=()
[[ ${#FILTERED[@]} -gt 0 ]] && AVAILABLE=("${FILTERED[@]}")

NEXT=$((HIGHEST + 1))
while [[ ${#AVAILABLE[@]} -lt $COUNT ]]; do
    if ! number_taken "$NEXT"; then
        AVAILABLE+=("$NEXT")
    fi
    NEXT=$((NEXT + 1))
done
AVAILABLE=("${AVAILABLE[@]:0:$COUNT}")

echo "  Existing in Viam: ${#EXISTING_NUMS[@]} machines"
echo ""
echo "About to create ${COUNT} machine(s):"
echo "  Org:      ${ORG_NAME:-<unresolved>}   (${ORG})"
echo "  Location: ${LOC_NAME:-<unresolved>}   (${LOCATION})"
echo "  Names:    $(printf "${PREFIX}-%s " "${AVAILABLE[@]}")"
echo ""
read -p "Continue? [Y/n] " CONFIRM
case "${CONFIRM:-y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 1 ;;
esac
echo ""

# Create machines and stage credentials
QUEUE="[]"

echo "Creating $COUNT machines..."
echo ""

for i in "${AVAILABLE[@]}"; do
    NAME="${PREFIX}-${i}"
    SLOT_ID="slot-${NAME}"
    SLOT_DIR="${MACHINES_DIR}/${SLOT_ID}"

    echo -n "  ${NAME}... "

    CREATE_OUTPUT=$(viam machines create --name="$NAME" --organization="$ORG" --location="$LOCATION" 2>&1)
    MACHINE_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[a-f0-9-]{36}' | head -1)

    if [[ -z "$MACHINE_ID" ]]; then
        echo "FAILED to parse machine ID from: $CREATE_OUTPUT"
        continue
    fi

    PARTS_OUTPUT=$(viam machines part list --organization="$ORG" --machine="$MACHINE_ID" 2>&1)
    PART_ID=$(echo "$PARTS_OUTPUT" | grep -oE '[a-f0-9-]{36}' | head -1 || true)

    if [[ -z "$PART_ID" ]]; then
        echo "FAILED to get part ID from: $PARTS_OUTPUT"
        continue
    fi

    mkdir -p "$SLOT_DIR"
    CRED_OUTPUT=$("$PYTHON" "$FETCH_CREDS" --part-id="$PART_ID" --output="${SLOT_DIR}/viam.json" 2>&1)

    if [[ ! -f "${SLOT_DIR}/viam.json" ]]; then
        echo "FAILED to fetch credentials: $CRED_OUTPUT"
        continue
    fi

    QUEUE=$(echo "$QUEUE" | "$PYTHON" -c "
import json, sys
q = json.load(sys.stdin)
q.append({'slot_id': '${SLOT_ID}', 'name': '${NAME}', 'assigned': False})
json.dump(q, sys.stdout)
")

    echo "OK (machine: ${MACHINE_ID}, part: ${PART_ID})"
done

echo ""
python3 "$QUEUE_STORE" append --queue-dir "$MACHINES_DIR" <<< "$QUEUE"

echo ""
echo "=== Provisioning Complete ==="
echo "  Machines created: ${COUNT}"
echo "  Queue: just status"
echo ""
echo "Next:"
echo "  Pi SD card:  just flash-batch"
echo "  x86 PXE:     just serve"
echo "  x86 USB:     just flash-usb-batch && just serve-usb"
