#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
TEMPLATE="${REPO_ROOT}/templates/user-data.tpl"
OUTPUT="${REPO_ROOT}/http-server/autoinstall/user-data"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Load site config ---

[[ -f "$SITE_CONFIG" ]] || die "config/site.env not found. Run 'just setup-wizard' to create it."
source "$SITE_CONFIG"

SSH_PUBLIC_KEY=$(cat "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}" 2>/dev/null) \
    || die "SSH public key not found at ${SSH_PUBLIC_KEY_FILE}"

PASSWORD_HASH=$(echo "$PASSWORD" | mkpasswd -m sha-512 --stdin 2>/dev/null) \
    || PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")

# --- PXE server address ---

HTTP_PORT="${HTTP_PORT:-8234}"
if [[ -z "${PXE_SERVER:-}" ]]; then
    if command -v ip &>/dev/null; then
        PXE_IP=$(ip -o -4 addr show "$(ip route | awk '/default/ {print $5; exit}')" | awk '{print $4}' | cut -d/ -f1)
    else
        PXE_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
        PXE_IP=$(ifconfig "$PXE_IFACE" 2>/dev/null | awk '/inet / {print $2}')
    fi
    PXE_SERVER="${PXE_IP}:${HTTP_PORT}"
fi

# --- Generate user-data ---

export SSH_PUBLIC_KEY PASSWORD_HASH PXE_SERVER
export USERNAME="${USERNAME:-viam}"
export TIMEZONE="${TIMEZONE:-America/New_York}"
export WIFI_SSID="${WIFI_SSID:-}"
export WIFI_PASSWORD="${WIFI_PASSWORD:-}"
export PROVISION_MODE="${PROVISION_MODE:-os-only}"
export TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

envsubst '${SSH_PUBLIC_KEY} ${PASSWORD_HASH} ${PXE_SERVER} ${USERNAME} ${TIMEZONE} ${WIFI_SSID} ${WIFI_PASSWORD} ${PROVISION_MODE} ${TAILSCALE_AUTH_KEY}' \
    < "${TEMPLATE}" > "${OUTPUT}"

# --- Stage Tailscale key for HTTP serving (if provided) ---

mkdir -p "${REPO_ROOT}/http-server/config"
if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    echo "$TAILSCALE_AUTH_KEY" > "${REPO_ROOT}/http-server/config/tailscale.key"
    echo "  Tailscale key staged"
fi

echo "Generated ${OUTPUT}"
echo "  PXE server: ${PXE_SERVER}"
echo "  SSH key: ${SSH_PUBLIC_KEY:0:40}..."
echo "  Mode: ${PROVISION_MODE}"
