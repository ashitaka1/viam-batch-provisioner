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

# Homebrew installs some tools (notably dnsmasq) into sbin, which is often
# absent from PATH even after `brew install` succeeds. Look there before
# declaring a tool missing, or the check contradicts brew itself.
have() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null && return 0
    if [[ "$OS" == "Darwin" ]]; then
        local dir
        for dir in /opt/homebrew/sbin /usr/local/sbin; do
            [[ -x "$dir/$cmd" ]] && return 0
        done
    fi
    return 1
}

MISSING=()           # required tools — a missing one fails the check
OPTIONAL_MISSING=()  # mode-specific tools — reported but never fatal
check() {
    local cmd="$1" pkg="$2" purpose="$3" tier="${4:-required}"
    if have "$cmd"; then
        printf "  ✓ %-12s %s\n" "$cmd" "($purpose)"
    elif [[ "$tier" == "optional" ]]; then
        printf "  ⚠ %-12s %s — x86 only, install with: %s %s\n" "$cmd" "($purpose)" "$INSTALLER" "$pkg"
        OPTIONAL_MISSING+=("$pkg")
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

# x86-only — Pi SD provisioning never touches these, so a missing one warns
# rather than blocking the wizard or a Pi operator.
check 7z      p7zip        "ISO extraction (just setup)"           optional
check dnsmasq dnsmasq      "PXE DHCP proxy + TFTP (just serve)"    optional

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
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Missing: ${MISSING[*]}"
    echo "Install all at once: ${INSTALLER} ${MISSING[*]}"
    exit 1
fi

if [[ ${#OPTIONAL_MISSING[@]} -gt 0 ]]; then
    echo "All required prerequisites satisfied."
    echo "Skipping x86-only tools (not needed for Pi SD): ${OPTIONAL_MISSING[*]}"
    echo "Install them before x86 provisioning: ${INSTALLER} ${OPTIONAL_MISSING[*]}"
else
    echo "All prerequisites satisfied."
fi
exit 0
