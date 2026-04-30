#!/usr/bin/env bash
# Pick the network interface that target machines should reach the
# provisioning HTTP server on. Used by USB-mode flashing (where the
# server IP is baked into each stick's GRUB config) and by `just
# serve-usb` (so build-config.sh stamps the same IP into user-data).
#
# Lists candidate interfaces (UP, IPv4, non-loopback, non-link-local),
# scores them (default-route iface first, wired ahead of wireless),
# and either prints the top pick or — with --interactive — asks the
# operator to confirm.
#
# Output (stdout): "<iface> <ipv4>" — e.g., "en0 192.168.1.50"
# Diagnostic / prompt text goes to stderr so command substitution stays clean.
#
# Usage:
#   ./scripts/pick-server-iface.sh                   # silent, top pick
#   ./scripts/pick-server-iface.sh --interactive     # prompt to confirm

set -euo pipefail

INTERACTIVE=0
[[ "${1:-}" == "--interactive" ]] && INTERACTIVE=1

OS="$(uname -s)"

# Returns lines of: "<iface> <ipv4>"
list_candidates() {
    if [[ "$OS" == "Darwin" ]]; then
        # ifconfig — list every interface that's up and has an inet addr
        for iface in $(ifconfig -lu); do
            local ip
            ip=$(ifconfig "$iface" 2>/dev/null \
                 | awk '/^\tinet / && $2 !~ /^127\./ && $2 !~ /^169\.254\./ {print $2; exit}')
            [[ -n "$ip" ]] && echo "$iface $ip"
        done
    else
        # Linux: parse `ip -o -4 addr show`
        ip -o -4 addr show 2>/dev/null \
          | awk '$2 != "lo" {split($4, a, "/"); ip=a[1];
                 if (ip !~ /^127\./ && ip !~ /^169\.254\./) print $2, ip}'
    fi
}

# Returns the iface name of the default route (or empty string)
default_iface() {
    if [[ "$OS" == "Darwin" ]]; then
        route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
    else
        ip -o route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
    fi
}

# Lower score = better. Prefers default-route iface, then wired (en0/eth*/enp*),
# then anything else.
score_iface() {
    local iface="$1"
    local default="$2"
    local score=50
    [[ "$iface" == "$default" ]] && score=$((score - 20))
    case "$iface" in
        en*|eth*|enp*|eno*) score=$((score - 10)) ;;
        wl*|wlan*|wlp*)     score=$((score + 5))  ;;
        utun*|tun*|tap*|bridge*|awdl*|llw*|anpi*|ap*) score=$((score + 30)) ;;
    esac
    echo "$score"
}

DEFAULT=$(default_iface)

# Build scored list: "<score> <iface> <ipv4>"
SCORED=$(list_candidates | while read -r iface ip; do
    [[ -z "$iface" ]] && continue
    score=$(score_iface "$iface" "$DEFAULT")
    echo "$score $iface $ip"
done | sort -n)

if [[ -z "$SCORED" ]]; then
    echo "ERROR: No usable network interface found (need an UP interface with an IPv4 address)." >&2
    exit 1
fi

if [[ "$INTERACTIVE" -eq 1 ]]; then
    echo "" >&2
    echo "Available interfaces (target machines must reach this host on the chosen one):" >&2
    i=1
    declare -a CHOICES=()
    while read -r score iface ip; do
        marker=""
        [[ "$iface" == "$DEFAULT" ]] && marker=" (default route)"
        printf "  %d) %-12s %s%s\n" "$i" "$iface" "$ip" "$marker" >&2
        CHOICES+=("$iface $ip")
        i=$((i + 1))
    done <<< "$SCORED"

    echo "" >&2
    read -r -p "Pick interface [1]: " PICK </dev/tty
    PICK="${PICK:-1}"

    if [[ ! "$PICK" =~ ^[0-9]+$ ]] || (( PICK < 1 || PICK > ${#CHOICES[@]} )); then
        echo "ERROR: Invalid choice." >&2
        exit 1
    fi
    echo "${CHOICES[$((PICK - 1))]}"
else
    echo "$SCORED" | head -1 | awk '{print $2, $3}'
fi
