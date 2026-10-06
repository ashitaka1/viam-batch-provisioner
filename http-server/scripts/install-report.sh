#!/bin/sh
# Report install progress or failure to the provisioner.
#
# Runs inside the Ubuntu installer, fetched from the file server by the
# autoinstall config. It never fails the install: it always exits 0.
#
#   install-report.sh <host:port> progress <stage>
#   install-report.sh <host:port> failed <stage|auto> [reason]
#
# Stages: installer late-commands identity tooling tailscale done.
# `auto` uses the stage last recorded by a progress call, or `installer` if
# there has been none. The reason is cut down to a safe character set and 400
# characters here, and the server cleans it again.
#
# The machine is identified by the viam_hostname= kernel argument (USB), or
# else by each ethernet NIC's MAC address in turn until the server accepts one
# (PXE). Only the NIC the server assigned answers 200.
#
# REPORT_STATE_DIR, REPORT_CMDLINE and REPORT_SYS_NET point the script at
# fixtures in tests.

SERVER="$1"
KIND="$2"
STAGE="$3"
REASON="$4"
STATE_DIR="${REPORT_STATE_DIR:-/tmp}"
CMDLINE="${REPORT_CMDLINE:-/proc/cmdline}"
SYS_NET="${REPORT_SYS_NET:-/sys/class/net}"
MARKER="$STATE_DIR/viam-install-stage"

[ -n "$SERVER" ] || exit 0
case "$KIND" in
    progress|failed) ;;
    *) exit 0 ;;
esac

if [ "$STAGE" = auto ]; then
    STAGE=$(cat "$MARKER" 2>/dev/null)
    [ -n "$STAGE" ] || STAGE=installer
fi
case "$STAGE" in
    installer|late-commands|identity|tooling|tailscale|done) ;;
    *) exit 0 ;;
esac

# Remember the stage before any network call, so a later failure can say where
# it happened even if the server can't be reached now.
if [ "$KIND" = progress ]; then
    echo "$STAGE" > "$MARKER" 2>/dev/null
fi

command -v curl >/dev/null 2>&1 || exit 0

REASON=$(printf '%s' "$REASON" | tr -c 'A-Za-z0-9 ._:/=,()-' ' ' | cut -c1-400)

# post <name|mac> <value>: true when the server accepted the report.
post() {
    body="{\"kind\":\"$KIND\",\"stage\":\"$STAGE\",\"$1\":\"$2\""
    if [ "$KIND" = failed ] && [ -n "$REASON" ]; then
        body="$body,\"reason\":\"$REASON\""
    fi
    body="$body}"
    curl -sf --connect-timeout 3 --max-time 5 \
        -H 'Content-Type: application/json' -d "$body" \
        "http://$SERVER/api/v1/install-reports" >/dev/null 2>&1
}

NAME=$(tr ' ' '\n' < "$CMDLINE" 2>/dev/null | sed -n 's/^viam_hostname=//p' | head -n 1 | tr -cd 'a-z0-9-')
if [ -n "$NAME" ]; then
    post name "$NAME"
else
    for dir in "$SYS_NET"/en* "$SYS_NET"/eth*; do
        [ -r "$dir/address" ] || continue
        MAC=$(tr 'A-F' 'a-f' < "$dir/address" | tr -cd '0-9a-f:')
        [ -n "$MAC" ] || continue
        post mac "$MAC" && break
    done
fi

exit 0
