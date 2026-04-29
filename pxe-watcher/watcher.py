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


def _chown_to_invoker(path: Path):
    """Set ownership to the user who invoked sudo, not root."""
    uid = int(os.environ.get("SUDO_UID", -1))
    gid = int(os.environ.get("SUDO_GID", -1))
    if uid >= 0:
        os.chown(path, uid, gid)


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
    _chown_to_invoker(machine_dir)

    # Write hostname
    hostname_file = machine_dir / "hostname"
    hostname_file.write_text(name)
    _chown_to_invoker(hostname_file)

    # Copy viam.json from the slot's staged credentials (full mode only —
    # os-only/agent queues have no slot_id and no per-slot credentials).
    slot_id = slot.get("slot_id")
    if slot_id:
        viam_json_src = queue_dir / slot_id / "viam.json"
        if viam_json_src.exists():
            viam_json_dst = machine_dir / "viam.json"
            viam_json_dst.write_text(viam_json_src.read_text())
            _chown_to_invoker(viam_json_dst)

    # Write machine info
    info = {
        "name": name,
        "mac": mac,
        "assigned_at": datetime.now(timezone.utc).isoformat(),
    }
    info_file = machine_dir / "machine-info.json"
    info_file.write_text(json.dumps(info, indent=2))
    _chown_to_invoker(info_file)

    # Mark as assigned in queue.json. Match on name — it's 1:1 with the
    # slot in both full mode (which also has slot_id) and os-only/agent
    # mode (which doesn't), so name is the queue-wide identity key.
    slot["assigned"] = True
    slot["mac"] = mac
    queue_file = queue_dir / "queue.json"
    with open(queue_file) as f:
        all_slots = json.load(f)
    for s in all_slots:
        if s["name"] == slot["name"]:
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

    # tcpdump with -v shows DHCP options (including Vendor-Class / PXEClient)
    # so we can distinguish PXE boots from regular DHCP traffic.
    cmd = [
        "tcpdump", "-l", "-n", "-e", "-v",
        "-i", interface,
        "udp", "port", "67",
    ]

    mac_pattern = re.compile(r"Request from ([0-9a-f:]{17})", re.IGNORECASE)

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )

    def shutdown(signum, frame):
        proc.terminate()
        print("\n")
        print_summary(queue_dir)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    def handle_packet(lines: list[str]):
        """Process a complete tcpdump packet. Only acts on PXE DHCP Discovers."""
        packet_text = "\n".join(lines)
        if "PXEClient" not in packet_text:
            return

        match = mac_pattern.search(packet_text)
        if not match:
            return

        mac = match.group(1).lower()
        if mac in seen_macs:
            return
        seen_macs.add(mac)

        now = datetime.now().strftime("%H:%M:%S")
        info = assign_machine(queue_dir, queue, mac)

        if info:
            print(f"[{now}] New PXE client: MAC {mac} → assigned {info['name']}")
            if not queue:
                print(f"[{now}] All machines assigned!")
                print_summary(queue_dir)
        else:
            print(f"[{now}] New PXE client: MAC {mac} → NO SLOTS REMAINING (ignored)")

    # With -v, tcpdump prints multi-line output per packet.
    # New packets start with a timestamp (non-whitespace); continuation
    # lines start with whitespace.
    current_packet: list[str] = []

    for line in proc.stdout:
        if line and not line[0].isspace():
            if current_packet:
                handle_packet(current_packet)
            current_packet = [line]
        else:
            current_packet.append(line)


def detect_interface() -> str:
    """Find the default route interface."""
    import platform

    try:
        if platform.system() == "Darwin":
            result = subprocess.run(
                ["route", "-n", "get", "default"],
                capture_output=True, text=True,
            )
            for line in result.stdout.splitlines():
                if "interface:" in line:
                    return line.split()[-1]
        else:
            result = subprocess.run(
                ["ip", "-o", "route", "show", "default"],
                capture_output=True, text=True,
            )
            parts = result.stdout.split()
            if "dev" in parts:
                return parts[parts.index("dev") + 1]
    except Exception:
        pass

    print("ERROR: Could not detect default network interface.", file=sys.stderr)
    print("  Specify one with --interface", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Watch for PXE boot clients and assign machine names")
    parser.add_argument(
        "--interface", "-i",
        default=None,
        help="Network interface to listen on (default: auto-detect from default route)",
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

    interface = args.interface or detect_interface()
    watch(interface, args.queue_dir)


if __name__ == "__main__":
    main()
