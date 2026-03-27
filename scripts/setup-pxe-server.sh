#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UBUNTU_DIR="${REPO_ROOT}/http-server/ubuntu"
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"
ISO_FILE="${REPO_ROOT}/ubuntu-24.04.4-live-server-amd64.iso"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "=== TCOS PXE Server Setup ==="

# --- Extract kernel + initrd from Ubuntu ISO ---

if [[ -f "${UBUNTU_DIR}/vmlinuz" && -f "${UBUNTU_DIR}/initrd" ]]; then
    echo "Ubuntu kernel+initrd already present, skipping download."
else
    echo "Downloading Ubuntu 24.04 Server ISO..."
    if [[ ! -f "${ISO_FILE}" ]]; then
        curl -fL --progress-bar -o "${ISO_FILE}" "${ISO_URL}"
    else
        echo "  ISO already downloaded."
    fi

    echo "Extracting vmlinuz and initrd..."
    if command -v 7z &>/dev/null; then
        7z e "${ISO_FILE}" casper/vmlinuz casper/initrd -o"${UBUNTU_DIR}" -y
    elif [[ "$(uname)" == "Linux" ]]; then
        MOUNT_DIR=$(mktemp -d)
        sudo mount -o loop,ro "${ISO_FILE}" "${MOUNT_DIR}"
        cp "${MOUNT_DIR}/casper/vmlinuz" "${UBUNTU_DIR}/vmlinuz"
        cp "${MOUNT_DIR}/casper/initrd" "${UBUNTU_DIR}/initrd"
        sudo umount "${MOUNT_DIR}"
        rmdir "${MOUNT_DIR}"
    else
        die "Install p7zip (brew install p7zip) or run on Linux to extract the ISO"
    fi

    echo "  vmlinuz: $(du -h "${UBUNTU_DIR}/vmlinuz" | cut -f1)"
    echo "  initrd:  $(du -h "${UBUNTU_DIR}/initrd" | cut -f1)"
fi

# --- Check config files ---

echo ""
echo "Checking config files..."
MISSING=0
for f in ssh_host_key.pub tailscale.key viam-credentials.env; do
    if [[ -f "${REPO_ROOT}/config/${f}" ]]; then
        echo "  ✓ config/${f}"
    else
        echo "  ✗ config/${f} — copy from ${f}.example and fill in"
        MISSING=1
    fi
done

if [[ "${MISSING}" -eq 1 ]]; then
    echo ""
    echo "Add missing config files, then run: ./scripts/build-config.sh"
else
    echo ""
    echo "All config present. Run: ./scripts/build-config.sh"
fi

echo "Then: docker compose up"
