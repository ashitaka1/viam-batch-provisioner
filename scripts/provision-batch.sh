#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
MACHINES_DIR="${REPO_ROOT}/http-server/machines"
FETCH_CREDS="${REPO_ROOT}/scripts/fetch-credentials.py"
PYTHON="${REPO_ROOT}/.venv/bin/python3"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Parse arguments ---

COUNT=""
PREFIX=""
LOCATION=""
ORG=""
BATCH_CONFIG=""

usage() {
    cat <<EOF
Usage: $0 --config FILE [--count N] [--prefix PREFIX] [--location-id ID] [--org-id ID]
       $0 --count N --prefix PREFIX --location-id ID --org-id ID

  --config FILE      Batch config file (sources all values; CLI flags override)
  --count N          Number of machines to provision
  --prefix PREFIX    Name prefix, e.g. lab-meerkat, lab-nuc
  --location-id ID   Viam location ID
  --org-id ID        Viam organization ID

Config file format (shell variables):
  COUNT=6
  PREFIX=lab-meerkat
  VIAM_ORG_ID=...
  VIAM_LOCATION_ID=...
  VIAM_API_KEY_ID=...
  VIAM_API_KEY=...

Requires:
  - viam CLI (authenticated, or credentials in config file)
  - Python 3 with viam-sdk: pip install viam-sdk
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)      BATCH_CONFIG="$2"; shift 2 ;;
        --count)       COUNT="$2"; shift 2 ;;
        --prefix)      PREFIX="$2"; shift 2 ;;
        --location-id) LOCATION="$2"; shift 2 ;;
        --org-id)      ORG="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             die "Unknown argument: $1" ;;
    esac
done

# --- Load config file (CLI flags take precedence) ---

CLI_COUNT="$COUNT"
CLI_PREFIX="$PREFIX"
CLI_LOCATION="$LOCATION"
CLI_ORG="$ORG"

if [[ -n "$BATCH_CONFIG" ]]; then
    [[ -f "$BATCH_CONFIG" ]] || die "Config file not found: $BATCH_CONFIG"
    source "$BATCH_CONFIG"
elif [[ -f "${CONFIG_DIR}/viam-credentials.env" ]]; then
    source "${CONFIG_DIR}/viam-credentials.env"
fi

COUNT="${CLI_COUNT:-${COUNT:-}}"
PREFIX="${CLI_PREFIX:-${PREFIX:-}}"
LOCATION="${CLI_LOCATION:-${VIAM_LOCATION_ID:-}}"
ORG="${CLI_ORG:-${VIAM_ORG_ID:-}}"
[[ -n "$COUNT" ]]    || die "--count is required"
[[ -n "$PREFIX" ]]   || die "--prefix is required (e.g. --prefix lab-meerkat)"
[[ -n "$LOCATION" ]] || die "--location-id is required (or set VIAM_LOCATION_ID in config/viam-credentials.env)"
[[ -n "$ORG" ]]      || die "--org-id is required (or set VIAM_ORG_ID in config/viam-credentials.env)"
[[ -n "${VIAM_API_KEY_ID:-}" ]] || die "VIAM_API_KEY_ID is required in config/viam-credentials.env"
[[ -n "${VIAM_API_KEY:-}" ]]    || die "VIAM_API_KEY is required in config/viam-credentials.env"
export VIAM_API_KEY_ID VIAM_API_KEY

# --- Check dependencies ---

command -v viam &>/dev/null || die "viam CLI not found. Install from https://docs.viam.com/dev/tools/cli/"
[[ -x "$PYTHON" ]] || die "Python venv not found. Run: python3 -m venv .venv && .venv/bin/pip install viam-sdk"
"$PYTHON" -c "import viam" 2>/dev/null || die "viam-sdk not installed. Run: .venv/bin/pip install viam-sdk"

# --- Authenticate CLI ---

echo "Authenticating with Viam..."
viam login api-key --key-id="$VIAM_API_KEY_ID" --key="$VIAM_API_KEY"

# --- Check for existing batch state ---

QUEUE_FILE="${MACHINES_DIR}/queue.json"
if [[ -f "$QUEUE_FILE" ]]; then
    UNASSIGNED=$("$PYTHON" -c "
import json
q = json.load(open('$QUEUE_FILE'))
print(sum(1 for s in q if not s.get('assigned')))
")
    if [[ "$UNASSIGNED" -gt 0 ]]; then
        die "There are ${UNASSIGNED} unassigned machines in the current queue. Run 'make clean' before starting a new batch, or 'make reset' to re-use the current queue."
    fi
    # Previous batch fully assigned — clean up stale state
    echo "Cleaning up previous batch..."
    rm -rf "${MACHINES_DIR}"/slot-*
    rm -rf "${MACHINES_DIR}"/[0-9a-f][0-9a-f]:* 2>/dev/null || true
    rm -f "$QUEUE_FILE"
fi

# --- Find available machine numbers (fills gaps first, then appends) ---

echo "Listing existing machines with prefix '${PREFIX}'..."
EXISTING=$(viam machines list --organization="$ORG" --location="$LOCATION" 2>/dev/null || true)

EXISTING_NUMS=()
while IFS= read -r line; do
    if [[ "$line" =~ ${PREFIX}-([0-9]+) ]]; then
        EXISTING_NUMS+=("$((10#${BASH_REMATCH[1]}))")
    fi
done <<< "$EXISTING"

# Find available numbers: gaps first, then beyond the highest
AVAILABLE=()
HIGHEST=0
for n in "${EXISTING_NUMS[@]:-}"; do
    (( n > HIGHEST )) && HIGHEST=$n
done

# Scan 1..highest for gaps
for (( n=1; n<=HIGHEST; n++ )); do
    FOUND=0
    for e in "${EXISTING_NUMS[@]:-}"; do
        [[ "$e" -eq "$n" ]] && FOUND=1 && break
    done
    [[ "$FOUND" -eq 0 ]] && AVAILABLE+=("$n")
done

# Fill from gaps, then append beyond highest
NEXT=$((HIGHEST + 1))
while [[ ${#AVAILABLE[@]} -lt $COUNT ]]; do
    AVAILABLE+=("$NEXT")
    NEXT=$((NEXT + 1))
done

# Take only what we need
AVAILABLE=("${AVAILABLE[@]:0:$COUNT}")

echo "  Existing: ${#EXISTING_NUMS[@]} machines"
echo "  Will create: ${AVAILABLE[*]}"

# --- Create machines and stage credentials ---

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

    # Create machine via CLI
    CREATE_OUTPUT=$(viam machines create --name="$NAME" --organization="$ORG" --location="$LOCATION" 2>&1)
    MACHINE_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[a-f0-9-]{36}' | head -1)

    if [[ -z "$MACHINE_ID" ]]; then
        echo "FAILED to parse machine ID from: $CREATE_OUTPUT"
        continue
    fi

    # Get the main part ID from part list output (format: "ID: <uuid>")
    PARTS_OUTPUT=$(viam machines part list --organization="$ORG" --machine="$MACHINE_ID" 2>&1)
    PART_ID=$(echo "$PARTS_OUTPUT" | grep -oE '[a-f0-9-]{36}' | head -1 || true)

    if [[ -z "$PART_ID" ]]; then
        echo "FAILED to get part ID from: $PARTS_OUTPUT"
        continue
    fi

    # Fetch cloud credentials via Python SDK using provisioning key
    mkdir -p "$SLOT_DIR"
    CRED_OUTPUT=$("$PYTHON" "$FETCH_CREDS" --part-id="$PART_ID" --output="${SLOT_DIR}/viam.json" 2>&1)

    if [[ ! -f "${SLOT_DIR}/viam.json" ]]; then
        echo "FAILED to fetch credentials: $CRED_OUTPUT"
        continue
    fi

    # Add to queue
    QUEUE=$(echo "$QUEUE" | "$PYTHON" -c "
import json, sys
q = json.load(sys.stdin)
q.append({'slot_id': '${SLOT_ID}', 'name': '${NAME}', 'assigned': False})
json.dump(q, sys.stdout)
")

    echo "OK (machine: ${MACHINE_ID}, part: ${PART_ID})"
done

# --- Write queue file ---

echo "$QUEUE" | "$PYTHON" -m json.tool > "${MACHINES_DIR}/queue.json"

echo ""
echo "=== Provisioning Complete ==="
echo "  Machines created: ${COUNT}"
echo "  Queue file: ${MACHINES_DIR}/queue.json"
echo "  Credential slots: ${MACHINES_DIR}/slot-*/"
echo ""
echo "Next steps:"
echo "  1. Start the PXE server:  docker compose up -d"
echo "  2. Start the watcher:     sudo python3 pxe-watcher/watcher.py -i <interface>"
echo "  3. Power on machines one at a time (F10 for network boot)"
