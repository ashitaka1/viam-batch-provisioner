#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="${REPO_ROOT}/config/environments"
SITE_CONFIG="${REPO_ROOT}/config/site.env"

mkdir -p "$ENV_DIR"

echo "=== Viam Lab Provisioner Setup ==="
echo ""

# --- Check for existing environments ---

EXISTING=($(ls "$ENV_DIR"/*.env 2>/dev/null || true))

if [[ ${#EXISTING[@]} -gt 0 ]]; then
    echo "Existing environments:"
    for i in "${!EXISTING[@]}"; do
        NAME=$(basename "${EXISTING[$i]}" .env)
        MODE=$(grep '^PROVISION_MODE=' "${EXISTING[$i]}" 2>/dev/null | cut -d= -f2)
        WIFI=$(grep '^WIFI_SSID=' "${EXISTING[$i]}" 2>/dev/null | cut -d= -f2)
        echo "  $((i+1))) ${NAME}  (mode: ${MODE:-?}, wifi: ${WIFI:-none})"
    done
    echo "  n) Create new environment"
    echo ""
    read -p "Choose [n]: " CHOICE
    CHOICE="${CHOICE:-n}"

    if [[ "$CHOICE" != "n" && "$CHOICE" =~ ^[0-9]+$ ]]; then
        IDX=$((CHOICE - 1))
        if [[ $IDX -ge 0 && $IDX -lt ${#EXISTING[@]} ]]; then
            SELECTED="${EXISTING[$IDX]}"
            ENV_NAME=$(basename "$SELECTED" .env)
            ln -sf "environments/${ENV_NAME}.env" "$SITE_CONFIG"
            echo ""
            echo "Activated: ${ENV_NAME}"
            echo "  config/site.env → config/environments/${ENV_NAME}.env"
            echo ""
            echo "Provision with: just provision <prefix> <count>"
            exit 0
        fi
    fi
    echo ""
fi

# --- Environment name ---

echo "New environment:"
read -p "  Name (e.g., tcos, hackathon, office-lab): " ENV_NAME
[[ -n "$ENV_NAME" ]] || { echo "Name required."; exit 1; }

ENV_FILE="${ENV_DIR}/${ENV_NAME}.env"
if [[ -f "$ENV_FILE" ]]; then
    read -p "  '${ENV_NAME}' already exists. Overwrite? (y/n) [n]: " OVERWRITE
    [[ "$OVERWRITE" == "y" ]] || { echo "Keeping existing."; exit 0; }
fi
echo ""

# --- OS account ---

echo "OS account:"
read -p "  Username [viam]: " USERNAME
USERNAME="${USERNAME:-viam}"
read -p "  Password [checkmate]: " PASSWORD
PASSWORD="${PASSWORD:-checkmate}"
echo ""

# --- Network ---

echo "Network:"
read -p "  WiFi SSID (blank to skip): " WIFI_SSID
WIFI_PASSWORD=""
if [[ -n "$WIFI_SSID" ]]; then
    read -p "  WiFi password: " WIFI_PASSWORD
fi
read -p "  Timezone [America/New_York]: " TIMEZONE
TIMEZONE="${TIMEZONE:-America/New_York}"
echo ""

# --- SSH ---

echo "SSH access:"
echo "  Provisioned machines need an SSH public key so you can log in."
echo "  You can generate a dedicated keypair, or use an existing key."
echo ""

SSH_PUBLIC_KEY_FILE=""
DEFAULT_KEY_NAME="id_${ENV_NAME}"
read -p "  Generate a new keypair '${DEFAULT_KEY_NAME}'? (y/n) [y]: " GEN_KEY
GEN_KEY="${GEN_KEY:-y}"

if [[ "$GEN_KEY" == "y" ]]; then
    KEY_PATH="$HOME/.ssh/${DEFAULT_KEY_NAME}"
    if [[ -f "$KEY_PATH" ]]; then
        echo "  Key already exists at ${KEY_PATH}"
    else
        echo "  Generating ${KEY_PATH}..."
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "${ENV_NAME}-provisioner"
    fi
    SSH_PUBLIC_KEY_FILE="${KEY_PATH}.pub"

    SSH_CONFIG="$HOME/.ssh/config"
    echo ""
    echo "  To make 'ssh <machine-name>' work, add a Host block to ~/.ssh/config"
    echo "  for each prefix you use. Example:"
    echo ""
    echo "    Host my-prefix-*"
    echo "      User ${USERNAME}"
    echo "      IdentityFile ${KEY_PATH}"
    echo ""
    read -p "  Add a Host block now? Enter prefix (blank to skip): " SSH_PREFIX
    if [[ -n "$SSH_PREFIX" ]]; then
        if grep -q "Host ${SSH_PREFIX}-\*" "$SSH_CONFIG" 2>/dev/null; then
            echo "  SSH config already has a '${SSH_PREFIX}-*' block."
        else
            cat >> "$SSH_CONFIG" <<SSHEOF

Host ${SSH_PREFIX}-*
    User ${USERNAME}
    IdentityFile ${KEY_PATH}
SSHEOF
            chmod 600 "$SSH_CONFIG"
            echo "  Added '${SSH_PREFIX}-*' to ${SSH_CONFIG}"
        fi
    fi
else
    read -p "  Path to existing SSH public key [~/.ssh/id_ed25519.pub]: " SSH_PUBLIC_KEY_FILE
    SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}"
    EXPANDED="${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"
    if [[ ! -f "$EXPANDED" ]]; then
        echo "  WARNING: ${SSH_PUBLIC_KEY_FILE} not found."
    fi
fi
echo ""

# --- Viam Cloud ---

echo "Viam Cloud:"
echo "  Provision modes:"
echo "    full    — create machines in Viam, install viam-agent, deploy credentials"
echo "    agent   — install viam-agent binary (users set up Viam themselves)"
echo "    os-only — just configure the OS, no Viam software"
echo ""
read -p "  Provision mode [os-only]: " PROVISION_MODE
PROVISION_MODE="${PROVISION_MODE:-os-only}"

VIAM_API_KEY_ID=""
VIAM_API_KEY=""
VIAM_ORG_ID=""
VIAM_LOCATION_ID=""

if [[ "$PROVISION_MODE" == "full" ]]; then
    echo ""
    echo "  You need a Viam API key with permission to create machines."
    echo "  Create one at app.viam.com > Organization Settings > API Keys."
    echo ""
    read -p "  API Key ID: " VIAM_API_KEY_ID
    read -p "  API Key: " VIAM_API_KEY
    read -p "  Organization ID: " VIAM_ORG_ID
    read -p "  Location ID: " VIAM_LOCATION_ID
fi
echo ""

# --- Tailscale ---

echo "Tailscale (optional):"
echo "  Provide an auth key to auto-join machines to your Tailscale network."
echo "  Generate one at: https://login.tailscale.com/admin/settings/keys"
echo ""
read -p "  Tailscale auth key (blank to skip): " TAILSCALE_AUTH_KEY
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
echo ""

# --- Write config ---

cat > "$ENV_FILE" <<EOF
# Environment: ${ENV_NAME}
# Generated by setup-wizard. Edit directly or re-run 'just setup-wizard'.

# OS account
USERNAME=${USERNAME}
PASSWORD=${PASSWORD}

# Network
WIFI_SSID=${WIFI_SSID}
WIFI_PASSWORD=${WIFI_PASSWORD}
TIMEZONE=${TIMEZONE}

# SSH
SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE}

# Viam Cloud
PROVISION_MODE=${PROVISION_MODE}
VIAM_API_KEY_ID=${VIAM_API_KEY_ID}
VIAM_API_KEY=${VIAM_API_KEY}
VIAM_ORG_ID=${VIAM_ORG_ID}
VIAM_LOCATION_ID=${VIAM_LOCATION_ID}

# Tailscale
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
EOF

# Symlink as active environment
ln -sf "environments/${ENV_NAME}.env" "$SITE_CONFIG"

echo "Saved: config/environments/${ENV_NAME}.env"
echo "Active: config/site.env → config/environments/${ENV_NAME}.env"
echo ""
echo "=== Next steps ==="
echo "  1. just provision <prefix> <count>"
echo "  2. just serve            (PXE: starts all services + watcher)"
echo "     just flash-batch      (Pi: batch SD card flashing)"
