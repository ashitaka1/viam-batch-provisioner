#!/usr/bin/env bash
# Follow the nginx access log and print each request compactly.
# Guard files are written by pxe-watcher, which tails the same log.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${1:-${REPO_ROOT}/logs/access.log}"

if [[ ! -f "$LOG" ]]; then
    echo "No access log at $LOG yet (starts with the HTTP server)." >&2
fi

# nginx combined access log: 192.168.65.1 - - [22/Apr/2026:13:24:58 -0400] "GET /path HTTP/1.1" 200 1234 "-" "agent" "-"
ACCESS_RE='\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:([0-9:]{8})[^]]*\] "([A-Z]+) ([^ ]+) [^"]+" ([0-9]+)'

tail -n 50 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" =~ $ACCESS_RE ]]; then
        printf '%s  %-4s %-60s %s\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        echo "$line"
    fi
done
