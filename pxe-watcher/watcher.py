#!/usr/bin/env python3
"""
PXE Watcher — listens for DHCP Discover packets on the provisioning network,
assigns machine names to MACs in arrival order, and stages per-machine
credential files for the HTTP server.

Usage:
    sudo ./watcher.py --interface eth0 --queue-dir ../http-server/machines

Requires: tcpdump (installed on most Linux systems)
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_queue(queue_dir: Path) -> list[dict]:
    """Load the provisioning queue — slot dirs containing viam.json but no mac-assigned marker."""
    slots = []
    queue_file = queue_dir / "queue.json"
    if not queue_file.exists():
        return slots

    with open(queue_file) as f:
        slots = json.load(f)

    # Filter to unassigned slots
    return [s for s in slots if not s.get("assigned")]


def assign_machine(queue_dir: Path, queue: list[dict], mac: str) -> dict | None:
    """Assign the next queued name to a MAC address.

    Creates the MAC-keyed directory with hostname and viam.json,
    and marks the slot as assigned in queue.json.
    """
    if not queue:
        return None

    slot = queue.pop(0)
    name = slot["name"]
    machine_dir = queue_dir / mac

    machine_dir.mkdir(parents=True, exist_ok=True)

    # Write hostname
    (machine_dir / "hostname").write_text(name)

    # Copy viam.json from the slot's staged credentials
    slot_dir = queue_dir / slot["slot_id"]
    viam_json_src = slot_dir / "viam.json"
    if viam_json_src.exists():
        (machine_dir / "viam.json").write_text(viam_json_src.read_text())

    # Write machine info
    info = {
        "name": name,
        "mac": mac,
        "assigned_at": datetime.now(timezone.utc).isoformat(),
    }
    (machine_dir / "machine-info.json").write_text(json.dumps(info, indent=2))

    # Mark as assigned in queue.json
    slot["assigned"] = True
    slot["mac"] = mac
    queue_file = queue_dir / "queue.json"
    with open(queue_file) as f:
        all_slots = json.load(f)
    for s in all_slots:
        if s["slot_id"] == slot["slot_id"]:
            s["assigned"] = True
            s["mac"] = mac
            break
    with open(queue_file, "w") as f:
        json.dump(all_slots, f, indent=2)

    return info


def print_summary(queue_dir: Path):
    """Print the full MAC → name mapping table."""
    queue_file = queue_dir / "queue.json"
    if not queue_file.exists():
        return

    with open(queue_file) as f:
        slots = json.load(f)

    assigned = [s for s in slots if s.get("assigned")]
    if not assigned:
        return

    print("\n--- Assignment Summary ---")
    print(f"{'Name':<25} {'MAC':<20}")
    print("-" * 45)
    for s in assigned:
        print(f"{s['name']:<25} {s.get('mac', 'N/A'):<20}")
    print("-" * 45)


def watch(interface: str, queue_dir: Path):
    """Sniff DHCP Discover packets via tcpdump and assign names."""
    queue_dir = queue_dir.resolve()
    queue = load_queue(queue_dir)
    seen_macs: set[str] = set()

    # Load already-assigned MACs
    queue_file = queue_dir / "queue.json"
    if queue_file.exists():
        with open(queue_file) as f:
            for s in json.load(f):
                if s.get("mac"):
                    seen_macs.add(s["mac"])

    remaining = len(queue)
    print(f"PXE Watcher started on {interface}")
    print(f"  Queue directory: {queue_dir}")
    print(f"  Machines waiting: {remaining}")
    if remaining == 0:
        print("  WARNING: No machines queued. Run provision-batch.sh first.")
    print("  Listening for PXE boot requests...\n")

    # tcpdump: capture DHCP traffic (port 67 = server, port 68 = client)
    # -l = line-buffered, -n = no DNS, -e = show link-layer header
    cmd = [
        "tcpdump", "-l", "-n", "-e",
        "-i", interface,
        "udp", "port", "67",
    ]

    # MAC pattern in tcpdump BOOTP/DHCP output
    mac_pattern = re.compile(r"Request from ([0-9a-f:]{17})", re.IGNORECASE)

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    def shutdown(signum, frame):
        proc.terminate()
        print("\n")
        print_summary(queue_dir)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    for line in proc.stdout:
        match = mac_pattern.search(line)
        if not match:
            continue

        mac = match.group(1).lower()

        if mac in seen_macs:
            continue
        seen_macs.add(mac)

        now = datetime.now().strftime("%H:%M:%S")
        info = assign_machine(queue_dir, queue, mac)

        if info:
            print(f"[{now}] New PXE client: MAC {mac} → assigned {info['name']}")
            remaining = len(queue)
            if remaining == 0:
                print(f"[{now}] All machines assigned!")
                print_summary(queue_dir)
        else:
            print(f"[{now}] New PXE client: MAC {mac} → NO SLOTS REMAINING (ignored)")


def main():
    parser = argparse.ArgumentParser(description="Watch for PXE boot clients and assign machine names")
    parser.add_argument(
        "--interface", "-i",
        required=True,
        help="Network interface to listen on (e.g., eth0)",
    )
    parser.add_argument(
        "--queue-dir", "-q",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "http-server" / "machines",
        help="Directory containing queue.json and credential slots (default: ../http-server/machines)",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: Must run as root (tcpdump needs raw socket access)", file=sys.stderr)
        print(f"  Try: sudo {' '.join(sys.argv)}", file=sys.stderr)
        sys.exit(1)

    watch(args.interface, args.queue_dir)


if __name__ == "__main__":
    main()
