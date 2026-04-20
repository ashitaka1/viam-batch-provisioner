# PXE/SD provisioning commands

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
    sudo dnsmasq --conf-file=netboot/dnsmasq.conf --tftp-root={{justfile_directory()}}/netboot --log-facility={{justfile_directory()}}/dnsmasq.log
    echo "Starting PXE watcher (Ctrl-C to stop all)..."
    echo ""
    sudo {{justfile_directory()}}/.venv/bin/python3 {{justfile_directory()}}/pxe-watcher/watcher.py

# Stop all PXE services
stop:
    #!/usr/bin/env bash
    echo "Stopping services..."
    sudo killall dnsmasq 2>/dev/null && echo "  dnsmasq stopped" || echo "  dnsmasq not running"
    docker compose down 2>/dev/null && echo "  Docker stopped" || echo "  Docker not running"

# Start PXE watcher only (assigns names to MACs as machines boot)
watch:
    sudo .venv/bin/python3 pxe-watcher/watcher.py

# Start dnsmasq proxy DHCP + TFTP server only
dhcp:
    sudo dnsmasq --conf-file=netboot/dnsmasq.conf --tftp-root={{justfile_directory()}}/netboot --log-facility={{justfile_directory()}}/dnsmasq.log --no-daemon 2>&1 | grep -v '^dnsmasq-dhcp'

# Start HTTP server only (Docker)
up:
    docker compose up -d

# Stop HTTP server only
down:
    docker compose down

# Generate autoinstall user-data from template + secrets
build-config:
    ./scripts/build-config.sh

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

# Reset queue (mark all slots unassigned, re-use same batch)
reset:
    #!/usr/bin/env bash
    echo "Resetting queue (marking all slots as unassigned)..."
    .venv/bin/python3 -c "import json; \
      q=json.load(open('http-server/machines/queue.json')); \
      [s.update({'assigned': False, 'mac': None}) for s in q]; \
      json.dump(q, open('http-server/machines/queue.json', 'w'), indent=2)"
    echo "Cleaning MAC-keyed directories..."
    rm -rf http-server/machines/[0-9a-f][0-9a-f]:*
    echo "Done. Queue ready for re-use."

# Wipe all provisioning state (between batches)
clean:
    #!/usr/bin/env bash
    echo "Removing all provisioning state from http-server/machines/..."
    rm -rf http-server/machines/[0-9a-f][0-9a-f]:*
    rm -rf http-server/machines/slot-*
    rm -f http-server/machines/queue.json
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
