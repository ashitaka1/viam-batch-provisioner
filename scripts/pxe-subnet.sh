#!/usr/bin/env bash
# Print the dnsmasq proxy-DHCP range for the provisioning network as
# "<network>,proxy,<netmask>", e.g. "192.168.7.0,proxy,255.255.255.0".
#
# The range comes from PXE_PROXY_SUBNET in config/site.env (CIDR, e.g.
# 10.1.0.0/20) when set; otherwise from the IPv4 address and netmask of
# the given interface, or of the default-route interface.
#
# Usage:
#   ./scripts/pxe-subnet.sh [IFACE]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONFIG="${REPO_ROOT}/config/site.env"
OS="$(uname -s)"

die() { echo "ERROR: $*" >&2; exit 1; }

ip_to_int() {
    local IFS=. a b c d
    read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

prefix_to_mask_int() {
    local bits="$1"
    (( bits >= 0 && bits <= 32 )) || die "bad prefix length /$bits"
    if (( bits == 0 )); then echo 0; else echo $(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
}

if [[ -z "${PXE_PROXY_SUBNET:-}" && -f "$SITE_CONFIG" ]]; then
    PXE_PROXY_SUBNET="$(sed -n 's/^PXE_PROXY_SUBNET=//p' "$SITE_CONFIG" | tr -d '"'"'" | tail -1)"
fi

if [[ -n "${PXE_PROXY_SUBNET:-}" ]]; then
    [[ "$PXE_PROXY_SUBNET" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})/([0-9]{1,2})$ ]] \
        || die "PXE_PROXY_SUBNET must be CIDR like 10.1.0.0/20, got '$PXE_PROXY_SUBNET'"
    ADDR_INT="$(ip_to_int "${BASH_REMATCH[1]}")"
    MASK_INT="$(prefix_to_mask_int "${BASH_REMATCH[3]}")"
else
    IFACE="${1:-}"
    if [[ -z "$IFACE" ]]; then
        if [[ "$OS" == "Darwin" ]]; then
            IFACE="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
        else
            IFACE="$(ip -o route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
        fi
    fi
    [[ -n "$IFACE" ]] || die "no default-route interface; pass one or set PXE_PROXY_SUBNET in config/site.env"

    if [[ "$OS" == "Darwin" ]]; then
        read -r ADDR MASK_HEX < <(ifconfig "$IFACE" 2>/dev/null \
            | awk '/^\tinet / && $2 !~ /^169\.254\./ {print $2, $4; exit}')
        [[ -n "${ADDR:-}" ]] || die "$IFACE has no IPv4 address"
        ADDR_INT="$(ip_to_int "$ADDR")"
        MASK_INT=$(( MASK_HEX ))
    else
        read -r ADDR PREFIX < <(ip -o -4 addr show "$IFACE" 2>/dev/null \
            | awk '{split($4, a, "/"); print a[1], a[2]; exit}')
        [[ -n "${ADDR:-}" ]] || die "$IFACE has no IPv4 address"
        ADDR_INT="$(ip_to_int "$ADDR")"
        MASK_INT="$(prefix_to_mask_int "$PREFIX")"
    fi
fi

echo "$(int_to_ip $(( ADDR_INT & MASK_INT ))),proxy,$(int_to_ip "$MASK_INT")"
