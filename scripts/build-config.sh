#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
TEMPLATE="${REPO_ROOT}/templates/user-data.tpl"
OUTPUT="${REPO_ROOT}/http-server/autoinstall/user-data"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Load config ---

[[ -f "${CONFIG_DIR}/viam-credentials.env" ]] || die "Missing config/viam-credentials.env (copy from .example)"
[[ -f "${CONFIG_DIR}/ssh_host_key.pub" ]]     || die "Missing config/ssh_host_key.pub"
[[ -f "${CONFIG_DIR}/tailscale.key" ]]         || die "Missing config/tailscale.key"

SSH_PUBLIC_KEY=$(cat "${CONFIG_DIR}/ssh_host_key.pub")

# Generate password hash
PASSWORD_HASH=$(echo 'checkmate' | mkpasswd -m sha-512 --stdin 2>/dev/null) \
  || PASSWORD_HASH=$(openssl passwd -6 'checkmate')

# --- PXE server address ---

PXE_SERVER="${PXE_SERVER:-\$(ip route | awk '/default/ {print \$3}')}"

# --- Generate user-data ---

export SSH_PUBLIC_KEY PASSWORD_HASH PXE_SERVER
envsubst '${SSH_PUBLIC_KEY} ${PASSWORD_HASH} ${PXE_SERVER}' < "${TEMPLATE}" > "${OUTPUT}"

# --- Stage Tailscale key for HTTP serving ---

mkdir -p "${REPO_ROOT}/http-server/config"
grep -v '^#' "${CONFIG_DIR}/tailscale.key" | tr -d '[:space:]' > "${REPO_ROOT}/http-server/config/tailscale.key"

echo "Generated ${OUTPUT}"
echo "  SSH key: ${SSH_PUBLIC_KEY:0:40}..."
echo "  Tailscale key staged to http-server/config/tailscale.key"
