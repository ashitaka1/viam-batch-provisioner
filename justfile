# PXE/SD provisioning commands

# Verify host tools (p7zip, dnsmasq, docker, python3, viam CLI) are installed
doctor:
    ./scripts/check-prereqs.sh --full

# Interactive setup — creates config/site.env
setup-wizard:
    ./scripts/setup-wizard.sh

# Start all PXE services, run watcher in foreground. Ctrl-C stops everything.
serve:
    #!/usr/bin/env bash
    set -euo pipefail
    cleanup() {
        echo ""
        echo "Shutting down..."
        sudo killall dnsmasq 2>/dev/null && echo "  dnsmasq stopped" || true
        docker compose down 2>/dev/null && echo "  Docker stopped" || true
        echo "Done."
    }
    trap cleanup EXIT
    echo "Generating autoinstall config..."
    ./scripts/build-config.sh
    echo ""
    echo "Starting HTTP server..."
    docker compose up -d
    echo "Starting dnsmasq (DHCP proxy + TFTP)..."
    # --user=root: dnsmasq's default 'nobody' user can't traverse macOS home
    # directories, so TFTP fails with "Permission denied" reading netboot/.
    sudo dnsmasq --user=root --conf-file=netboot/dnsmasq.conf --tftp-root={{justfile_directory()}}/netboot --log-facility={{justfile_directory()}}/dnsmasq.log
    # Tail HTTP logs + create PXE guard files when hostname is fetched
    {{justfile_directory()}}/scripts/tail-http-logs.sh {{justfile_directory()}}/netboot/grub/provisioned &
    HTTP_LOG_PID=$!
    echo "Starting PXE watcher (Ctrl-C to stop all)..."
    echo ""
    sudo {{justfile_directory()}}/.venv/bin/python3 {{justfile_directory()}}/pxe-watcher/watcher.py
    kill $HTTP_LOG_PID 2>/dev/null || true

# Stop all PXE services
stop:
    #!/usr/bin/env bash
    echo "Stopping services..."
    sudo killall dnsmasq 2>/dev/null && echo "  dnsmasq stopped" || echo "  dnsmasq not running"
    docker compose down 2>/dev/null && echo "  Docker stopped" || echo "  Docker not running"

# --- Debug helpers (individual services; `just serve` runs them together) ---

# Start PXE watcher only (assigns names to MACs as machines boot)
watch:
    sudo .venv/bin/python3 pxe-watcher/watcher.py

# Start dnsmasq proxy DHCP + TFTP server only
dhcp:
    sudo dnsmasq --user=root --conf-file=netboot/dnsmasq.conf --tftp-root={{justfile_directory()}}/netboot --log-facility={{justfile_directory()}}/dnsmasq.log --no-daemon 2>&1 | grep -v '^dnsmasq-dhcp'

# Start HTTP server only (Docker)
up:
    docker compose up -d

# Stop HTTP server only
down:
    docker compose down

# Generate autoinstall user-data from template + secrets
build-config:
    ./scripts/build-config.sh

# --- Main flow targets resume below ---

# Extract GRUB, kernel, initrd from Ubuntu ISO (one-time setup)
setup:
    ./scripts/setup-pxe-server.sh

# Create machines / generate queue (prefix and count required)
provision prefix count:
    ./scripts/provision-batch.sh --prefix {{prefix}} --count {{count}}

# Flash a single Pi SD card
flash device name:
    ./scripts/flash-pi-sd.sh {{device}} {{name}}

# Flash all queued machines, prompting for SD card swaps
flash-batch:
    ./scripts/flash-batch.sh

# Flash a single x86 USB boot stick (talks to a fixed server, no PXE)
flash-usb device name:
    ./scripts/flash-usb.sh {{device}} {{name}}

# Flash one USB boot stick per queued machine, with swap prompts
flash-usb-batch:
    ./scripts/flash-usb-batch.sh

# Serve HTTP only (USB-mode targets — no DHCP/TFTP/watcher).
# Reads the address baked into the sticks (config/.server-address).
serve-usb:
    #!/usr/bin/env bash
    set -euo pipefail
    SERVER_FILE="{{justfile_directory()}}/config/.server-address"
    if [[ -f "$SERVER_FILE" ]]; then
        export PXE_SERVER="$(cat "$SERVER_FILE")"
        echo "Using server address from sticks: $PXE_SERVER"
    else
        echo "No saved server address. Run 'just flash-usb-batch' first, or"
        echo "set PXE_SERVER manually before invoking this command."
    fi
    cleanup() {
        echo ""
        echo "Stopping HTTP server..."
        docker compose down 2>/dev/null || true
    }
    trap cleanup EXIT
    echo "Generating autoinstall config..."
    ./scripts/build-config.sh
    echo ""
    echo "Starting HTTP server (Ctrl-C to stop)..."
    docker compose up

# Download Raspberry Pi OS Lite image
download-pi-image:
    #!/usr/bin/env bash
    if ls {{justfile_directory()}}/*raspios*.img {{justfile_directory()}}/pi-os.img 2>/dev/null | head -1 > /dev/null; then
        echo "Pi OS image already present."
    else
        echo "Downloading Raspberry Pi OS Lite (64-bit)..."
        URL=$(curl -fsSL "https://downloads.raspberrypi.com/raspios_lite_arm64/images/" | grep -oE 'raspios_lite_arm64-[0-9-]+/' | tail -1)
        IMG=$(curl -fsSL "https://downloads.raspberrypi.com/raspios_lite_arm64/images/${URL}" | grep -oE '[0-9a-z-]+raspios[^"]+\.img\.xz' | head -1)
        curl -fSL --progress-bar -o "{{justfile_directory()}}/${IMG}" "https://downloads.raspberrypi.com/raspios_lite_arm64/images/${URL}${IMG}"
        echo "Decompressing..."
        xz -dk "{{justfile_directory()}}/${IMG}"
        echo "Done: ${IMG%.xz}"
    fi

# Clear a single machine's PXE guard so it can re-attempt install
unguard slot:
    #!/usr/bin/env bash
    set -euo pipefail
    QUEUE_FILE=http-server/machines/queue.json
    if [ ! -f "$QUEUE_FILE" ]; then
        echo "No queue.json. Run 'just provision' first." >&2
        exit 1
    fi
    MAC=$(.venv/bin/python3 -c "
    import json, sys
    target = '{{slot}}'
    for s in json.load(open('$QUEUE_FILE')):
        if s.get('name') == target or s.get('mac') == target:
            mac = s.get('mac')
            if not mac:
                sys.exit(2)
            print(mac); sys.exit(0)
    sys.exit(1)
    ") || {
        rc=$?
        case $rc in
            1) echo "No slot matching '{{slot}}' (by name or MAC) in queue." >&2 ;;
            2) echo "Slot '{{slot}}' has no assigned MAC yet." >&2 ;;
        esac
        exit 1
    }
    just stop
    rm -f "netboot/grub/provisioned/$MAC.cfg"
    rm -f "http-server/machines/$MAC/machine-info.json"
    echo "Unguarded $MAC. Run 'just serve' and reboot the target."

# Reset queue (mark all slots unassigned, re-use same batch)
reset:
    #!/usr/bin/env bash
    echo "Resetting queue (marking all slots as unassigned)..."
    .venv/bin/python3 -c "import json; \
      q=json.load(open('http-server/machines/queue.json')); \
      [s.update({'assigned': False, 'mac': None}) for s in q]; \
      json.dump(q, open('http-server/machines/queue.json', 'w'), indent=2)"
    echo "Cleaning MAC-keyed directories and PXE guards..."
    rm -rf http-server/machines/[0-9a-f][0-9a-f]:*
    rm -rf netboot/grub/provisioned/
    echo "Done. Queue ready for re-use."

# Wipe all provisioning state (between batches)
clean:
    #!/usr/bin/env bash
    echo "Removing all provisioning state..."
    rm -rf http-server/machines/[0-9a-f][0-9a-f]:*
    rm -rf http-server/machines/slot-*
    rm -f http-server/machines/queue.json
    rm -rf netboot/grub/provisioned/
    echo "Clean. Run 'just provision' to start a new batch."

# Show queue state and service status
status:
    #!/usr/bin/env bash
    echo "=== Queue ==="
    if [ -f http-server/machines/queue.json ]; then
      python3 -c "import json; q=json.load(open('http-server/machines/queue.json')); \
        [print(f\"  {'✓' if s.get('assigned') else '○'} {s['name']:<25} {s.get('mac', 'waiting...')}\") for s in q]"
    else
      echo "  No queue. Run 'just provision' first."
    fi
    echo ""
    echo "=== Services ==="
    docker compose ps --format 'table {{{{.Name}}}}\t{{{{.Status}}}}' 2>/dev/null || echo "  Docker not running"
    pgrep -x dnsmasq >/dev/null 2>&1 && echo "  dnsmasq: running" || echo "  dnsmasq: stopped"
