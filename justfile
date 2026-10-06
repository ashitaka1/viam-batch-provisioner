# PXE/SD provisioning commands

# Verify host tools (p7zip, dnsmasq, docker, python3, viam CLI) are installed
doctor:
    ./scripts/check-prereqs.sh --full

# Interactive setup — creates config/site.env
setup-wizard:
    ./scripts/setup-wizard.sh

dnsmasq_args := "--user=root --conf-file=netboot/dnsmasq.conf --tftp-root=" + justfile_directory() + "/netboot --log-facility=" + justfile_directory() + "/logs/dnsmasq.log --pid-file=" + justfile_directory() + "/logs/dnsmasq.pid"

# Start all PXE services, run watcher in foreground. Ctrl-C stops everything.
serve:
    #!/usr/bin/env bash
    set -euo pipefail
    if ./scripts/daemon.sh installed; then
        echo "The always-on daemons are installed. Use 'just daemon-status', or 'just stop-daemon' before 'just serve'." >&2
        exit 1
    fi
    mkdir -p logs
    cleanup() {
        echo ""
        echo "Shutting down..."
        if [[ -f logs/dnsmasq.pid ]]; then
            sudo kill "$(cat logs/dnsmasq.pid)" 2>/dev/null && echo "  dnsmasq stopped" || true
        fi
        ./scripts/api-service.sh stop
        docker compose down 2>/dev/null && echo "  Docker stopped" || true
        echo "Done."
    }
    trap cleanup EXIT
    echo "Generating autoinstall config..."
    ./scripts/build-config.sh
    echo ""
    echo "Starting HTTP server..."
    docker compose up -d
    echo "Starting provisioner API + Bonjour..."
    ./scripts/api-service.sh start
    DHCP_RANGE="$(./scripts/pxe-subnet.sh)"
    echo "Starting dnsmasq (DHCP proxy on ${DHCP_RANGE%%,*}, TFTP)..."
    # --user=root: dnsmasq's default 'nobody' user can't traverse macOS home
    # directories, so TFTP fails with "Permission denied" reading netboot/.
    sudo dnsmasq {{dnsmasq_args}} --dhcp-range="$DHCP_RANGE"
    echo "Starting PXE watcher (Ctrl-C to stop all; HTTP requests: just logs)..."
    echo ""
    sudo "$(command -v python3)" {{justfile_directory()}}/pxe-watcher/watcher.py

# Stop all PXE services
stop:
    #!/usr/bin/env bash
    if ./scripts/daemon.sh installed; then
        echo "The always-on daemons are installed; use 'just stop-daemon'." >&2
        exit 1
    fi
    echo "Stopping services..."
    ./scripts/api-service.sh stop
    if [[ -f logs/dnsmasq.pid ]] && sudo kill "$(cat logs/dnsmasq.pid)" 2>/dev/null; then
        echo "  dnsmasq stopped"
    else
        echo "  dnsmasq not running"
    fi
    docker compose down 2>/dev/null && echo "  Docker stopped" || echo "  Docker not running"

# --- Always-on server (launchd) ---

# Install dnsmasq, watcher, API and Bonjour as launchd daemons and start the HTTP server
serve-daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating autoinstall config..."
    ./scripts/build-config.sh
    mkdir -p logs
    echo ""
    echo "Starting HTTP server..."
    docker compose up -d
    echo ""
    ./scripts/daemon.sh install
    echo ""
    just daemon-status

# Remove the launchd daemons and stop the HTTP server
stop-daemon:
    #!/usr/bin/env bash
    ./scripts/daemon.sh uninstall
    docker compose down 2>/dev/null && echo "  Docker stopped" || echo "  Docker not running"

# Show daemon, HTTP server and queue state
daemon-status:
    #!/usr/bin/env bash
    echo "=== Daemons ==="
    ./scripts/daemon.sh status
    echo ""
    echo "=== HTTP server ==="
    docker compose ps --format 'table {{{{.Name}}\t{{{{.Status}}' 2>/dev/null || echo "  Docker not running"
    echo ""
    echo "=== Queue ==="
    python3 pxe-watcher/queue_store.py list

# Follow HTTP requests (nginx access log)
logs:
    ./scripts/tail-http-logs.sh

# Run the unit tests (uses .venv/bin/python3 when present so the OpenAPI
# contract test can import PyYAML + jsonschema)
test:
    #!/usr/bin/env bash
    PY=python3
    [[ -x .venv/bin/python3 ]] && PY=.venv/bin/python3
    "$PY" -m unittest discover -s pxe-watcher -p 'test_*.py'

# --- Debug helpers (individual services; `just serve` runs them together) ---

# Start PXE watcher only (assigns names to MACs as machines boot)
watch:
    sudo "$(command -v python3)" pxe-watcher/watcher.py

# Start the provisioner REST/SSE API only (foreground, as the operator)
api:
    python3 pxe-watcher/provisioner_api.py --port "$(./scripts/api-service.sh port)" --http-port "$(./scripts/api-service.sh http-port)"

# Start dnsmasq proxy DHCP + TFTP server only
dhcp:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p logs
    sudo dnsmasq {{dnsmasq_args}} --dhcp-range="$(./scripts/pxe-subnet.sh)" --no-daemon 2>&1 | grep -v '^dnsmasq-dhcp'

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
        ./scripts/api-service.sh stop
        docker compose down 2>/dev/null || true
    }
    trap cleanup EXIT
    echo "Generating autoinstall config..."
    ./scripts/build-config.sh
    echo ""
    echo "Starting provisioner API + Bonjour..."
    ./scripts/api-service.sh start
    echo "Starting HTTP server (Ctrl-C to stop)..."
    docker compose up

# Download Raspberry Pi OS Lite image
download-pi-image:
    #!/usr/bin/env bash
    shopt -s nullglob
    existing=("{{justfile_directory()}}"/*raspios*.img)
    if (( ${#existing[@]} )) || [[ -f "{{justfile_directory()}}/pi-os.img" ]]; then
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
    MAC=$(python3 -c "
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
    # Removes the guard and flags the machine, so its next PXE boot starts a new
    # attempt however long from now it happens. The running watcher picks it up.
    python3 pxe-watcher/watcher.py --rearm "$MAC"
    echo "Reboot the target. If its boot order puts the disk first, use the one-time boot menu to PXE."

# Reset queue (mark all slots unassigned, re-use same batch)
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Resetting queue (marking all slots as unassigned)..."
    python3 pxe-watcher/queue_store.py reset
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
    rm -f http-server/machines/queue.json http-server/machines/queue.lock
    rm -rf netboot/grub/provisioned/
    [[ -f logs/access.log ]] && : > logs/access.log || true
    echo "Clean. Run 'just provision' to start a new batch."

# Show queue state and service status
status:
    #!/usr/bin/env bash
    echo "=== Queue ==="
    python3 pxe-watcher/queue_store.py list
    echo ""
    echo "=== Services ==="
    docker compose ps --format 'table {{{{.Name}}\t{{{{.Status}}' 2>/dev/null || echo "  Docker not running"
    ./scripts/api-service.sh status
    if ./scripts/daemon.sh installed; then
      echo "  daemons: installed (just daemon-status)"
    elif [[ -f logs/dnsmasq.pid ]] && kill -0 "$(cat logs/dnsmasq.pid)" 2>/dev/null; then
      echo "  dnsmasq: running (just serve)"
    else
      echo "  dnsmasq: stopped"
    fi
