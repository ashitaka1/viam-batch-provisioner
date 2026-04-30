#!/usr/bin/env bash
# Verify all tools needed by the batch provisioner are installed.
# Collects every missing prereq before exiting so the user can install
# them in one go (vs hitting them piecemeal across `just setup`, `just
# serve`, `just provision`).
#
# Usage:
#   ./scripts/check-prereqs.sh           # checks tools needed for any mode
#   ./scripts/check-prereqs.sh --full    # also checks Viam CLI (for full mode)
#
# Exits 0 if all required tools are present, 1 otherwise.

set -euo pipefail

CHECK_FULL_MODE=0
[[ "${1:-}" == "--full" ]] && CHECK_FULL_MODE=1

OS="$(uname -s)"
case "$OS" in
    Darwin) INSTALLER="brew install" ;;
    Linux)  INSTALLER="apt install" ;;
    *)      INSTALLER="<your package manager> install" ;;
esac

MISSING=()
check() {
    local cmd="$1" pkg="$2" purpose="$3"
    if command -v "$cmd" &>/dev/null; then
        printf "  ✓ %-12s %s\n" "$cmd" "($purpose)"
    else
        printf "  ✗ %-12s %s — install: %s %s\n" "$cmd" "($purpose)" "$INSTALLER" "$pkg"
        MISSING+=("$pkg")
    fi
}

echo "=== Checking prerequisites ==="

# Required for everything
check just    just         "command runner"
check docker  "Docker Desktop" "HTTP server (nginx) for ISO + autoinstall"
check python3 python3      "queue + credentials scripting"

# Required for PXE (x86) provisioning
check 7z      p7zip        "ISO extraction (just setup)"
check dnsmasq dnsmasq      "PXE DHCP proxy + TFTP (just serve)"

# envsubst is needed by build-config.sh and flash-usb.sh (template stamping)
check envsubst gettext     "template substitution (build-config / flash-usb)"

# Tools used by the USB-mode flasher on Linux. macOS does this with diskutil
# which is part of the OS; Linux needs parted + dosfstools to format sticks.
if [[ "$OS" == "Linux" ]]; then
    check parted     parted      "USB partitioning (just flash-usb)"
    check mkfs.vfat  dosfstools  "FAT32 format for USB (just flash-usb)"
fi

# Required only when creating Viam machines
if [[ "$CHECK_FULL_MODE" -eq 1 ]]; then
    echo ""
    echo "=== full-mode extras ==="
    check viam viam "Viam CLI for machine creation"
fi

echo ""
if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "All prerequisites satisfied."
    exit 0
fi

echo "Missing: ${MISSING[*]}"
echo "Install all at once: ${INSTALLER} ${MISSING[*]}"
exit 1
