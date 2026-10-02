#!/usr/bin/env python3
"""
PXE Watcher — listens for DHCP Discover packets on the provisioning network,
assigns machine names to MACs in arrival order, stages per-machine credential
files for the HTTP server, and writes GRUB guards once a machine is installed.

Usage:
    sudo ./watcher.py --interface en0 --queue-dir ../http-server/machines

The watcher holds no state in memory. The queue is read from queue.json on
every PXE event and a MAC's assignment time comes from its machine-info.json,
so `just provision`, `just reset` and `just clean` take effect on a running
daemon.

Requires: tcpdump
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import queue_store  # noqa: E402

# Wait this long after first PXE from a MAC before writing the GRUB guard.
# Firmware retries DHCPDISCOVER several times before TFTP succeeds (observed
# bursts of 3-5 retries within ~15s on MS-01). Writing the guard during that
# window would abort the in-progress install. After 60s the install is well
# into kernel boot and any new DHCPDISCOVER is a post-install reboot.
REPEAT_PXE_THRESHOLD = timedelta(seconds=60)

MAC_RE = r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}"

# nginx combined format; the request field is the first quoted string.
HOSTNAME_FETCH_RE = re.compile(
    rf'^\S+ \S+ \S+ \[[^\]]*\] "GET /machines/({MAC_RE})/hostname HTTP/[0-9.]+" 200 ',
    re.IGNORECASE,
)

_guard_lock = threading.Lock()


def _guard_dir(queue_dir: Path) -> Path:
    """Locate the GRUB provisioned-guard directory relative to the queue dir."""
    return queue_dir.parent.parent / "netboot" / "grub" / "provisioned"


def write_guard(queue_dir: Path, mac: str) -> bool:
    """Write a GRUB guard file so future PXE boots from this MAC skip install.

    grub.cfg sources grub/provisioned/<MAC>.cfg; the file contains "exit",
    so GRUB exits and UEFI falls through to disk boot. Idempotent.

    Returns True if a new guard was written, False if one already existed.
    """
    with _guard_lock:
        guard_dir = _guard_dir(queue_dir)
        guard_dir.mkdir(parents=True, exist_ok=True)
        queue_store.chown_like(guard_dir, queue_dir)
        guard_file = guard_dir / f"{mac}.cfg"
        if guard_file.exists():
            return False
        guard_file.write_text("exit\n")
        queue_store.chown_like(guard_file, queue_dir)
        return True


def assigned_at(queue_dir: Path, mac: str) -> Optional[datetime]:
    """When this MAC was assigned, from its machine-info.json; None if never."""
    info_path = queue_dir / mac / "machine-info.json"
    if not info_path.exists():
        return None
    try:
        info = json.loads(info_path.read_text())
        return datetime.fromisoformat(info["assigned_at"])
    except (json.JSONDecodeError, KeyError, ValueError, OSError):
        # The directory exists but is unreadable; treat the moment we noticed
        # as the assignment time rather than reassigning a known machine.
        return datetime.now(timezone.utc)


def assign_machine(queue_dir: Path, mac: str, now: Optional[datetime] = None) -> Optional[dict]:
    """Assign the next queued name to a MAC address.

    Creates the MAC-keyed directory with hostname, viam.json (full mode)
    and machine-info.json, and marks the entry assigned in queue.json.
    """
    slot = queue_store.assign_next(queue_dir, mac)
    if slot is None:
        return None

    name = slot["name"]
    machine_dir = queue_dir / mac
    machine_dir.mkdir(parents=True, exist_ok=True)
    queue_store.chown_like(machine_dir, queue_dir)

    hostname_file = machine_dir / "hostname"
    hostname_file.write_text(name)
    queue_store.chown_like(hostname_file, queue_dir)

    # os-only/agent queues have no slot_id and no per-slot credentials.
    slot_id = slot.get("slot_id")
    if slot_id:
        viam_json_src = queue_dir / slot_id / "viam.json"
        if viam_json_src.exists():
            viam_json_dst = machine_dir / "viam.json"
            viam_json_dst.write_text(viam_json_src.read_text())
            queue_store.chown_like(viam_json_dst, queue_dir)

    info = {
        "name": name,
        "mac": mac,
        "assigned_at": (now or datetime.now(timezone.utc)).isoformat(),
    }
    info_file = machine_dir / "machine-info.json"
    info_file.write_text(json.dumps(info, indent=2))
    queue_store.chown_like(info_file, queue_dir)
    return info


class PxeTracker:
    """Decides what a PXE sighting or a hostname fetch means for a MAC.

    on_pxe returns one of "assigned", "no-slot", "retry", "guard",
    "guard-exists".
    """

    NO_SLOT_LOG_INTERVAL = timedelta(minutes=5)

    def __init__(self, queue_dir: Path, *, now: Optional[Callable[[], datetime]] = None, log: Callable[..., None] = print):
        self.queue_dir = queue_dir.resolve()
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.log = log
        # Only throttles the "no slot" log line; carries no assignment state.
        self._no_slot_logged: dict[str, datetime] = {}

    def _stamp(self) -> str:
        return datetime.now().strftime("%H:%M:%S")

    def on_pxe(self, mac: str) -> str:
        current = self.now()
        first = assigned_at(self.queue_dir, mac)
        if first is None:
            info = assign_machine(self.queue_dir, mac, now=current)
            if info is None:
                last = self._no_slot_logged.get(mac)
                if last is None or current - last >= self.NO_SLOT_LOG_INTERVAL:
                    self._no_slot_logged[mac] = current
                    self.log(f"[{self._stamp()}] New PXE client: MAC {mac} → NO SLOTS (will assign once provisioned)")
                return "no-slot"
            self._no_slot_logged.pop(mac, None)
            self.log(f"[{self._stamp()}] New PXE client: MAC {mac} → assigned {info['name']}")
            unassigned, _total = queue_store.summary(self.queue_dir)
            if unassigned == 0:
                self.log(f"[{self._stamp()}] Queue empty — run `just provision` to add machines")
            else:
                self.log(f"[{self._stamp()}] {unassigned} machine(s) still waiting")
            return "assigned"

        # Within the threshold it's a firmware DHCP retry during the initial
        # PXE. After it, a post-install reboot: install the GRUB guard.
        elapsed = current - first
        if elapsed < REPEAT_PXE_THRESHOLD:
            return "retry"
        if write_guard(self.queue_dir, mac):
            self.log(f"[{self._stamp()}] Repeat PXE: MAC {mac} ({int(elapsed.total_seconds())}s after first) → GRUB guard installed")
            return "guard"
        return "guard-exists"

    def on_hostname_fetch(self, mac: str) -> bool:
        """The installer fetched its hostname: the install reached late-commands."""
        wrote = write_guard(self.queue_dir, mac)
        if wrote:
            self.log(f"[{self._stamp()}] Hostname fetched by MAC {mac} → GRUB guard installed")
        return wrote


def parse_hostname_fetch(line: str) -> Optional[str]:
    """MAC from a successful hostname fetch in an nginx access-log line, else None."""
    m = HOSTNAME_FETCH_RE.match(line)
    return m.group(1).lower() if m else None


class LogTailer(threading.Thread):
    """Follow a log file like `tail -F`, delivering complete lines to on_line.

    start() opens the file and seeks to its end before the thread runs, so
    history is never replayed. Truncation (size shrinks below the read
    offset) and replacement (inode changes) reopen the file from the start;
    a missing file is waited for and then read from the start.
    """

    def __init__(self, path: Path, on_line: Callable[[str], None], stop_event: Optional[threading.Event] = None, poll: float = 0.5):
        super().__init__(name="log-tailer", daemon=True)
        self.path = Path(path)
        self.on_line = on_line
        self.poll = poll
        self.stop_event = stop_event or threading.Event()
        self.ready = threading.Event()
        self._fh = None
        self._ino = None
        self._pos = 0
        self._pending = b""

    def _open(self, from_end: bool) -> bool:
        try:
            fh = open(self.path, "rb")
        except FileNotFoundError:
            return False
        if from_end:
            fh.seek(0, os.SEEK_END)
        self._fh = fh
        self._ino = os.fstat(fh.fileno()).st_ino
        self._pos = fh.tell()
        self._pending = b""
        return True

    def _close(self) -> None:
        if self._fh is not None:
            self._fh.close()
        self._fh = None
        self._ino = None

    def _rotated(self) -> bool:
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return True
        return st.st_ino != self._ino or st.st_size < self._pos

    def start(self) -> None:
        self._open(from_end=True)
        super().start()

    def stop(self) -> None:
        self.stop_event.set()

    def run(self) -> None:
        self.ready.set()
        while not self.stop_event.is_set():
            if self._fh is None:
                if not self._open(from_end=False):
                    self.stop_event.wait(self.poll)
                    continue
            chunk = self._fh.readline()
            if chunk:
                self._pos += len(chunk)
                self._pending += chunk
                if self._pending.endswith(b"\n"):
                    line = self._pending[:-1].decode("utf-8", errors="replace")
                    self._pending = b""
                    self.on_line(line)
                continue
            if self._rotated():
                self._close()
                continue
            self.stop_event.wait(self.poll)
        self._close()


def print_summary(queue_dir: Path):
    """Print the full MAC → name mapping table."""
    try:
        entries = queue_store.read(queue_dir)
    except (json.JSONDecodeError, OSError):
        return
    assigned = [s for s in entries if s.get("assigned")]
    if not assigned:
        return
    print("\n--- Assignment Summary ---")
    print(f"{'Name':<25} {'MAC':<20}")
    print("-" * 45)
    for s in assigned:
        print(f"{s['name']:<25} {s.get('mac') or 'N/A':<20}")
    print("-" * 45)


def feed_packets(stream, handle_packet: Callable[[list[str]], None]) -> None:
    """Split tcpdump -v output into packets. A packet starts at a line with no
    leading whitespace; indented lines continue it."""
    current: list[str] = []
    for line in stream:
        if line and not line[0].isspace():
            if current:
                handle_packet(current)
            current = [line]
        else:
            current.append(line)
    if current:
        handle_packet(current)


def watch(interface: Optional[str], queue_dir: Path, access_log: Path, replay: Optional[str] = None):
    """Sniff DHCP Discover packets via tcpdump (or replay a capture) and assign names."""
    queue_dir = queue_dir.resolve()
    tracker = PxeTracker(queue_dir)

    try:
        unassigned, total = queue_store.summary(queue_dir)
    except json.JSONDecodeError as e:
        print(f"ERROR: {queue_dir / queue_store.QUEUE_FILE} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"PXE Watcher started on {interface or 'replay'}")
    print(f"  Queue directory: {queue_dir}")
    print(f"  Access log:      {access_log}")
    print(f"  Machines waiting: {unassigned} of {total}")
    if unassigned == 0:
        print("  No machines queued — run `just provision` to add some.")
    print("  Listening for PXE boot requests...\n")

    def on_log_line(line: str) -> None:
        mac = parse_hostname_fetch(line)
        if mac:
            tracker.on_hostname_fetch(mac)

    tailer = LogTailer(access_log, on_log_line)
    tailer.start()

    mac_pattern = re.compile(r"Request from ([0-9a-f:]{17})", re.IGNORECASE)

    def handle_packet(lines: list[str]):
        packet_text = "\n".join(lines)
        if "PXEClient" not in packet_text:
            return
        match = mac_pattern.search(packet_text)
        if not match:
            return
        tracker.on_pxe(match.group(1).lower())

    if replay is not None:
        stream = sys.stdin if replay == "-" else open(replay)
        feed_packets(stream, handle_packet)
        tailer.stop()
        print_summary(queue_dir)
        return

    # tcpdump with -v shows DHCP options (including Vendor-Class / PXEClient)
    # so we can distinguish PXE boots from regular DHCP traffic.
    cmd = ["tcpdump", "-l", "-n", "-e", "-v", "-i", interface, "udp", "port", "67"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def shutdown(signum, frame):
        tailer.stop()
        proc.terminate()
        print("\n")
        print_summary(queue_dir)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    feed_packets(proc.stdout, handle_packet)
    rc = proc.wait()
    err = proc.stderr.read().strip()
    tailer.stop()
    print(f"tcpdump exited rc={rc}{': ' + err if err else ''}", file=sys.stderr)
    sys.exit(1)


def detect_interface() -> str:
    """Find the default route interface."""
    import platform

    try:
        if platform.system() == "Darwin":
            result = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True)
            for line in result.stdout.splitlines():
                if "interface:" in line:
                    return line.split()[-1]
        else:
            result = subprocess.run(["ip", "-o", "route", "show", "default"], capture_output=True, text=True)
            parts = result.stdout.split()
            if "dev" in parts:
                return parts[parts.index("dev") + 1]
    except Exception:
        pass

    print("ERROR: Could not detect default network interface.", file=sys.stderr)
    print("  Specify one with --interface", file=sys.stderr)
    sys.exit(1)


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Watch for PXE boot clients and assign machine names")
    parser.add_argument("--interface", "-i", default=None,
                        help="Network interface to listen on (default: auto-detect from default route)")
    parser.add_argument("--queue-dir", "-q", type=Path, default=repo / "http-server" / "machines",
                        help="Directory containing queue.json and credential slots (default: ../http-server/machines)")
    parser.add_argument("--access-log", type=Path, default=repo / "logs" / "access.log",
                        help="nginx access log to watch for hostname fetches (default: ../logs/access.log)")
    parser.add_argument("--replay", metavar="FILE",
                        help="Read tcpdump -v output from FILE (or - for stdin) instead of sniffing; no root needed")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass

    if args.replay is not None:
        watch(None, args.queue_dir, args.access_log, replay=args.replay)
        return

    if os.geteuid() != 0:
        print("ERROR: Must run as root (tcpdump needs raw socket access)", file=sys.stderr)
        print(f"  Try: sudo {' '.join(sys.argv)}", file=sys.stderr)
        sys.exit(1)

    interface = args.interface or detect_interface()
    watch(interface, args.queue_dir, args.access_log)


if __name__ == "__main__":
    main()
