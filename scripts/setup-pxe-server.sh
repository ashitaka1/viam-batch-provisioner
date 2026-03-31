#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UBUNTU_DIR="${REPO_ROOT}/http-server/ubuntu"
NETBOOT_DIR="${REPO_ROOT}/netboot"
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"
ISO_FILE="${REPO_ROOT}/ubuntu-24.04.4-live-server-amd64.iso"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v 7z &>/dev/null || die "p7zip required. Install: brew install p7zip (macOS) or apt install p7zip-full (Linux)"

echo "=== PXE Server Setup ==="

# --- Download ISO ---

if [[ ! -f "${ISO_FILE}" ]]; then
    # Check common download locations
    for d in ~/Downloads ~/; do
        if [[ -f "${d}/$(basename ${ISO_URL})" ]]; then
            ISO_FILE="${d}/$(basename ${ISO_URL})"
            echo "Found ISO at ${ISO_FILE}"
            break
        fi
    done
fi

if [[ ! -f "${ISO_FILE}" ]]; then
    echo "Downloading Ubuntu 24.04 Server ISO..."
    curl -fL --progress-bar -o "${ISO_FILE}" "${ISO_URL}"
fi

echo "Using ISO: ${ISO_FILE}"

# --- Extract kernel + initrd for TFTP and HTTP ---

if [[ -f "${NETBOOT_DIR}/vmlinuz" && -f "${NETBOOT_DIR}/initrd" ]]; then
    echo "Kernel+initrd already present in netboot/, skipping."
else
    echo "Extracting kernel + initrd..."
    7z e "${ISO_FILE}" casper/vmlinuz casper/initrd -o"${NETBOOT_DIR}" -y -bso0
    echo "  vmlinuz: $(du -h "${NETBOOT_DIR}/vmlinuz" | cut -f1)"
    echo "  initrd:  $(du -h "${NETBOOT_DIR}/initrd" | cut -f1)"
fi

# Copy to HTTP server dir too (for url= ISO fetch, these aren't used directly
# but kept in sync)
mkdir -p "${UBUNTU_DIR}"
cp -n "${NETBOOT_DIR}/vmlinuz" "${UBUNTU_DIR}/vmlinuz" 2>/dev/null || true
cp -n "${NETBOOT_DIR}/initrd" "${UBUNTU_DIR}/initrd" 2>/dev/null || true

# --- Extract GRUB network boot binary + modules ---

if [[ -f "${NETBOOT_DIR}/grubx64.efi" ]]; then
    echo "GRUB binary already present, skipping."
else
    echo "Extracting GRUB network boot binary..."
    TMPDIR=$(mktemp -d)
    trap "rm -rf ${TMPDIR}" EXIT

    # Extract the signed GRUB deb from the ISO
    7z x "${ISO_FILE}" -o"${TMPDIR}" "pool/main/g/grub2-signed/grub-efi-amd64-signed_*.deb" -y -bso0
    DEB=$(ls "${TMPDIR}"/pool/main/g/grub2-signed/grub-efi-amd64-signed_*.deb)

    # Extract the network boot EFI binary from the deb
    cd "${TMPDIR}"
    ar x "${DEB}" data.tar.zst
    tar --use-compress-program=unzstd -xf data.tar.zst
    cd "${REPO_ROOT}"

    cp "${TMPDIR}/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" "${NETBOOT_DIR}/grubx64.efi"
    echo "  grubx64.efi: $(du -h "${NETBOOT_DIR}/grubx64.efi" | cut -f1)"
fi

# --- Extract GRUB modules ---

if [[ -d "${NETBOOT_DIR}/grub/x86_64-efi" ]]; then
    echo "GRUB modules already present, skipping."
else
    echo "Extracting GRUB modules..."
    mkdir -p "${NETBOOT_DIR}/grub"
    7z x "${ISO_FILE}" -o"${NETBOOT_DIR}/grub-tmp" "boot/grub/x86_64-efi" -y -bso0
    mv "${NETBOOT_DIR}/grub-tmp/boot/grub/x86_64-efi" "${NETBOOT_DIR}/grub/"
    rm -rf "${NETBOOT_DIR}/grub-tmp"
    echo "  Modules: $(ls "${NETBOOT_DIR}/grub/x86_64-efi/" | wc -l | tr -d ' ') files"
fi

# --- Stage ISO for HTTP serving ---

ISO_HTTP="${UBUNTU_DIR}/$(basename ${ISO_URL})"
if [[ ! -f "${ISO_HTTP}" ]]; then
    echo "Staging ISO for HTTP serving..."
    cp "${ISO_FILE}" "${ISO_HTTP}"
    echo "  ISO: $(du -h "${ISO_HTTP}" | cut -f1)"
else
    echo "ISO already staged for HTTP."
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

# --- Python venv ---

if [[ -x "${REPO_ROOT}/.venv/bin/python3" ]]; then
    echo "  ✓ .venv (Python)"
else
    echo "  ✗ .venv — run: python3 -m venv .venv && .venv/bin/pip install viam-sdk"
    MISSING=1
fi

echo ""
if [[ "${MISSING}" -eq 1 ]]; then
    echo "Fix missing items above, then run: ./scripts/build-config.sh"
else
    echo "All set. Run: ./scripts/build-config.sh"
fi
echo "Then: make up && make dhcp"
