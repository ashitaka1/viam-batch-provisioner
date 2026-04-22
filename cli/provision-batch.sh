#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FETCH_CREDS="${REPO_ROOT}/cli/fetch-credentials.py"
PYTHON="${REPO_ROOT}/.venv/bin/python3"
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

# --- Check for existing batch state ---

QUEUE_FILE="${MACHINES_DIR}/queue.json"
if [[ -f "$QUEUE_FILE" ]]; then
    UNASSIGNED=$(python3 -c "
import json
q = json.load(open('$QUEUE_FILE'))
print(sum(1 for s in q if not s.get('assigned')))
")
    if [[ "$UNASSIGNED" -gt 0 ]]; then
        echo "ERROR: Existing queue has ${UNASSIGNED} unassigned machine(s):" >&2
        python3 -c "
import json
q = json.load(open('$QUEUE_FILE'))
for s in q:
    status = '✓ assigned' if s.get('assigned') else '○ waiting'
    print(f\"  {status}  {s['name']}\")
" >&2
        echo "" >&2
        echo "Options:" >&2
        echo "  just clean    — wipe queue and start fresh" >&2
        echo "  just reset    — mark all as unassigned (re-flash same batch)" >&2
        exit 1
    fi
    echo "Cleaning up previous batch..."
    rm -rf "${MACHINES_DIR}"/slot-*
    rm -rf "${MACHINES_DIR}"/[0-9a-f][0-9a-f]:* 2>/dev/null || true
    rm -f "$QUEUE_FILE"
fi

# --- OS-only / agent mode: just generate names ---

if [[ "$PROVISION_MODE" != "full" ]]; then
    echo "Mode: ${PROVISION_MODE} (no Viam cloud provisioning)"
    echo ""

    mkdir -p "$MACHINES_DIR"
    QUEUE="[]"
    for i in $(seq 1 "$COUNT"); do
        NAME="${PREFIX}-${i}"
        QUEUE=$(python3 -c "
import json, sys
q = json.load(sys.stdin)
q.append({'name': '${NAME}', 'assigned': False})
json.dump(q, sys.stdout)
" <<< "$QUEUE")
    done
    echo "$QUEUE" | python3 -m json.tool > "${MACHINES_DIR}/queue.json"

    echo "=== Queue Ready ==="
    echo "  Machines: ${COUNT} (${PREFIX}-1 through ${PREFIX}-${COUNT})"
    echo "  Queue file: ${MACHINES_DIR}/queue.json"
    echo ""
    echo "Next: just flash-batch"
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
[[ -x "$PYTHON" ]] || die "Python venv not found. Run: python3 -m venv .venv && .venv/bin/pip install viam-sdk"
"$PYTHON" -c "import viam" 2>/dev/null || die "viam-sdk not installed. Run: .venv/bin/pip install viam-sdk"

echo "Authenticating with Viam..."
viam login api-key --key-id="$VIAM_API_KEY_ID" --key="$VIAM_API_KEY"

# Resolve org + location names so the operator knows where machines will land
LABELS=$("$PYTHON" "${REPO_ROOT}/cli/resolve-labels.py" --org-id="$ORG" --location-id="$LOCATION" 2>/dev/null || true)
ORG_NAME=$(echo "$LABELS" | sed -n 's/^ORG_NAME=//p')
LOC_NAME=$(echo "$LABELS" | sed -n 's/^LOCATION_NAME=//p')
echo ""
echo "About to create ${COUNT} machine(s):"
echo "  Org:      ${ORG_NAME:-<unresolved>}   (${ORG})"
echo "  Location: ${LOC_NAME:-<unresolved>}   (${LOCATION})"
echo "  Names:    ${PREFIX}-1 .. ${PREFIX}-${COUNT}"
echo ""
read -p "Continue? [Y/n] " CONFIRM
case "${CONFIRM:-y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 1 ;;
esac
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

NEXT=$((HIGHEST + 1))
while [[ ${#AVAILABLE[@]} -lt $COUNT ]]; do
    AVAILABLE+=("$NEXT")
    NEXT=$((NEXT + 1))
done
AVAILABLE=("${AVAILABLE[@]:0:$COUNT}")

echo "  Existing: ${#EXISTING_NUMS[@]} machines"
echo "  Will create: ${AVAILABLE[*]} (${COUNT} total)"

# Create machines and stage credentials
mkdir -p "$MACHINES_DIR"
QUEUE="[]"

echo ""
echo "Creating $COUNT machines..."
echo ""

for i in "${AVAILABLE[@]}"; do
    NAME="${PREFIX}-${i}"
    SLOT_ID="slot-${i}"
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

echo "$QUEUE" | "$PYTHON" -m json.tool > "${MACHINES_DIR}/queue.json"

echo ""
echo "=== Provisioning Complete ==="
echo "  Machines created: ${COUNT}"
echo "  Queue: just status"
echo ""
echo "Next: just flash-batch (Pi SD) or just serve (PXE)"
