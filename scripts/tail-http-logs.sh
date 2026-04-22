#!/usr/bin/env bash
# Tails HTTP server logs, prints them compactly, and creates PXE guard
# files when a machine's hostname is fetched (indicating successful install).

GUARD_DIR="${1:?Usage: $0 <guard-dir>}"
mkdir -p "$GUARD_DIR"

# nginx combined access log: 192.168.65.1 - - [22/Apr/2026:13:24:58 -0400] "GET /path HTTP/1.1" 200 1234 "-" "agent" "-"
ACCESS_RE='\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:([0-9:]{8})[^]]*\] "([A-Z]+) ([^ ]+) [^"]+" ([0-9]+)'

docker logs -f pxe-http 2>&1 | tr -d '\r' | while IFS= read -r line; do
    # Skip nginx startup noise (init scripts, worker/notice lines, entrypoint chatter)
    case "$line" in
        *.sh:*info:*|*worker*|*notice*|*entrypoint*|*"Configuration complete"*) continue ;;
    esac

    if [[ "$line" =~ $ACCESS_RE ]]; then
        printf '%s  %-4s %-60s %s\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        echo "$line"
    fi

    # When a machine fetches its hostname, the install succeeded.
    # Create a GRUB guard so it won't re-install on next PXE boot.
    MAC=$(echo "$line" | grep -oE 'GET /machines/[0-9a-f:]+/hostname.* 200' | sed 's|GET /machines/||;s|/hostname.*||')
    if [ -n "$MAC" ] && [ ! -f "$GUARD_DIR/$MAC.cfg" ]; then
        echo "exit" > "$GUARD_DIR/$MAC.cfg"
        echo "  [guard] PXE guard created for $MAC"
    fi
done
