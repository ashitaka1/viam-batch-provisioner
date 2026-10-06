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
import platform
import signal
import subprocess
import sys
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_journal  # noqa: E402
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

# Lock taken around every change to an existing machine-info.json.
INFO_LOCK = "info.lock"

# What a failure leaves in machine-info.json, cleared when it is recovered from.
INFO_FAILURE_KEYS = ("failed_at", "failure_reason", "failure_source")

# Everything a new attempt clears: the last attempt's outcome and progress.
RETRY_KEYS = ("completed_at",) + INFO_FAILURE_KEYS + ("stage", "progress_at", "armed")

# The hostname fetch writes the GRUB guard, and it happens in the `identity`
# section of the installer. A machine reporting one of these stages is past it.
GUARD_STAGES = ("tooling", "tailscale", "done")


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


def read_info(queue_dir: Path, mac: str) -> Optional[dict]:
    """The MAC's machine-info.json, or None if missing or unreadable."""
    try:
        info = json.loads((queue_dir / mac / "machine-info.json").read_text())
    except (OSError, ValueError):
        return None
    return info if isinstance(info, dict) else None


def write_info(queue_dir: Path, mac: str, info: dict) -> None:
    """Replace the MAC's machine-info.json atomically."""
    queue_store.atomic_write_json(queue_dir / mac / "machine-info.json", info, owner_ref=queue_dir, indent=2)


def update_info(queue_dir: Path, mac: str, mutate: Callable[[dict], bool]) -> Optional[dict]:
    """Read-modify-write one machine's machine-info.json under info.lock.

    The root watcher and the operator-run API both write this file, so every
    change to an existing one goes through here. mutate(info) edits the dict
    in place and returns True when it should be saved. Returns the dict as it
    stands afterwards, or None if the MAC has no machine-info.json. Raises
    TimeoutError if the lock can't be taken.
    """
    with queue_store.locked_file(queue_dir / INFO_LOCK, queue_dir, timeout=10.0):
        info = read_info(queue_dir, mac)
        if info is None:
            return None
        if mutate(info):
            write_info(queue_dir, mac, info)
        return info


def remove_guard(queue_dir: Path, mac: str) -> bool:
    """Delete the MAC's GRUB guard so its next PXE boot installs. True if one was removed."""
    with _guard_lock:
        try:
            (_guard_dir(queue_dir) / f"{mac}.cfg").unlink()
        except FileNotFoundError:
            return False
        return True


def parse_time(value) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None


def last_activity(info: dict) -> Optional[datetime]:
    """The later of assignment and the last progress report; None if a timestamp is unreadable."""
    times = [parse_time(info[key]) for key in ("assigned_at", "progress_at") if key in info]
    if not times or any(t is None for t in times):
        return None
    return max(times)


def _event(name: str, mac: Optional[str], now: datetime, **extra) -> dict:
    data = {"name": name, "timestamp": now.isoformat(timespec="seconds")}
    if mac:
        data["mac"] = mac
    data.update(extra)
    return data


def _emit_event(emit: Optional[Callable[[str, dict], None]], log: Callable[..., None], event_type: str, data: dict) -> None:
    """Record a lifecycle event. A failing journal never blocks a state change."""
    if emit is None:
        return
    try:
        emit(event_type, data)
    except Exception as e:
        log(f"WARNING: could not record {event_type} for {data.get('name')}: {e}")


def apply_failure(queue_dir: Path, *, name: str, mac: Optional[str], stage: str, reason: str, source: str,
                  now: datetime, emit: Optional[Callable[[str, dict], None]] = None,
                  log: Callable[..., None] = print, stale_before: Optional[datetime] = None) -> str:
    """Record that an install failed. Returns "recorded", "duplicate", "ignored" or "unknown".

    A PXE machine (mac given) keeps the failure in machine-info.json and loses
    its GRUB guard, so its next boot reinstalls. A USB machine (mac None) keeps
    it on its queue entry. The state is written before the event is emitted,
    so a journal failure can't cause a duplicate later.

    A report for a machine that has completed is ignored. A repeat is a
    duplicate, except that the installer's own report replaces a failure the
    timeout guessed at. With stale_before, a machine that showed activity
    after that moment is left alone: the timeout lost a race with a report.
    """
    when = now.isoformat(timespec="seconds")
    outcome = {"result": "duplicate"}  # what a mutate that records nothing leaves

    if mac is not None:
        def mutate(info: dict) -> bool:
            if info.get("completed_at"):
                outcome["result"] = "ignored"
                return False
            if stale_before is not None:
                activity = last_activity(info)
                if activity is None or activity > stale_before:
                    outcome["result"] = "ignored"
                    return False
            if info.get("failed_at") and not (info.get("failure_source") == "timeout" and source == "installer"):
                return False
            info.update(failed_at=when, failure_reason=reason, failure_source=source, stage=stage)
            outcome["result"] = "recorded"
            return True

        if update_info(queue_dir, mac, mutate) is None:
            return "unknown"
    else:
        def mutate_entry(entry: dict) -> bool:
            if entry.get("failed_at"):
                return False
            entry.update(failed_at=when, failure_reason=reason, stage=stage)
            outcome["result"] = "recorded"
            return True

        if queue_store.update_entry(queue_dir, name, mutate_entry) is None:
            return "unknown"

    if outcome["result"] == "recorded":
        if mac is not None:
            remove_guard(queue_dir, mac)
        _emit_event(emit, log, "install-failed", _event(name, mac, now, stage=stage, reason=reason, source=source))
    return outcome["result"]


def apply_progress(queue_dir: Path, *, name: str, mac: Optional[str], stage: str, now: datetime,
                   emit: Optional[Callable[[str, dict], None]] = None, log: Callable[..., None] = print) -> str:
    """Record that the installer entered a stage. Returns "recorded", "duplicate", "ignored" or "unknown".

    Every report moves a PXE machine's progress time, so an install that
    keeps reporting is never timed out; only a new stage (or a recovery)
    emits an event. A completed machine, and a machine the installer itself
    reported failed, are left alone. A failure the timeout guessed at is
    cleared, and the guard comes back if the machine is already past its
    hostname fetch.
    """
    when = now.isoformat(timespec="seconds")
    outcome = {"result": "recorded", "cleared": False}

    if mac is not None:
        def mutate(info: dict) -> bool:
            if info.get("completed_at"):
                outcome["result"] = "ignored"
                return False
            if info.get("failed_at"):
                if info.get("failure_source") != "timeout":
                    outcome["result"] = "ignored"
                    return False
                for key in INFO_FAILURE_KEYS:
                    info.pop(key, None)
                outcome["cleared"] = True
            if info.get("stage") == stage and not outcome["cleared"]:
                outcome["result"] = "duplicate"
            info["stage"] = stage
            info["progress_at"] = when
            return True

        if update_info(queue_dir, mac, mutate) is None:
            return "unknown"
    else:
        def mutate_entry(entry: dict) -> bool:
            if not entry.get("failed_at"):
                return False
            for key in queue_store.FAILURE_KEYS:
                entry.pop(key, None)
            outcome["cleared"] = True
            return True

        if queue_store.update_entry(queue_dir, name, mutate_entry) is None:
            return "unknown"

    if outcome["result"] != "recorded":
        return outcome["result"]
    if outcome["cleared"] and mac is not None and stage in GUARD_STAGES:
        write_guard(queue_dir, mac)
    _emit_event(emit, log, "install-progress", _event(name, mac, now, stage=stage))
    return "recorded"


def arm_retry(queue_dir: Path, mac: str) -> bool:
    """Make a machine reinstall on its next PXE boot, however long from now.

    This is `just unguard`. It clears the record of the last attempt, flags
    the machine so the next PXE sighting starts a new attempt instead of being
    taken for a reboot after a finished install, and removes the guard. False
    if the MAC has no machine-info.json.
    """
    def mutate(info: dict) -> bool:
        for key in RETRY_KEYS:
            info.pop(key, None)
        info["armed"] = True
        return True

    if update_info(queue_dir, mac, mutate) is None:
        return False
    remove_guard(queue_dir, mac)
    return True


def assign_machine(queue_dir: Path, mac: str, now: Optional[datetime] = None) -> Optional[dict]:
    """Assign the next queued name to a MAC address.

    Creates the MAC-keyed directory with hostname, viam.json (full mode)
    and machine-info.json, and marks the entry assigned in queue.json. An
    entry already assigned to this MAC (a crash between marking the queue
    and writing the files) is completed rather than a new one consumed.
    """
    slot = queue_store.find_by_mac(queue_dir, mac) or queue_store.assign_next(queue_dir, mac)
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

    # This is the first write of the MAC's machine-info.json, so it takes no
    # lock: the API can't address a MAC that has no machine-info yet.
    info = {
        "name": name,
        "mac": mac,
        "assigned_at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"),
        "attempt": 1,
    }
    write_info(queue_dir, mac, info)
    return info


class PxeTracker:
    """Decides what a PXE sighting or a hostname fetch means for a MAC.

    on_pxe returns one of "assigned", "no-slot", "retry", "guard",
    "guard-exists".
    """

    NO_SLOT_LOG_INTERVAL = timedelta(minutes=5)

    def __init__(self, queue_dir: Path, *, now: Optional[Callable[[], datetime]] = None, log: Callable[..., None] = print,
                 emit: Optional[Callable[[str, dict], None]] = None, install_timeout: Optional[timedelta] = None):
        self.queue_dir = queue_dir.resolve()
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.log = log
        self.emit = emit or (lambda _type, _data: None)
        # How long an install may go without any sign of life before it is
        # failed; None turns the sweep off.
        self.install_timeout = install_timeout
        # No install is failed before one full timeout has passed since the
        # watcher started, so a restart (or a host that was off) never fails
        # machines that simply weren't being watched.
        self.started_at = self.now()
        # Only throttles the "no slot" log line; carries no assignment state.
        self._no_slot_logged: dict[str, datetime] = {}

    def _stamp(self) -> str:
        return datetime.now().strftime("%H:%M:%S")

    def _emit(self, event_type: str, info: dict, **extra) -> None:
        _emit_event(self.emit, self.log, event_type, _event(info["name"], info["mac"], self.now(), **extra))

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
            self._emit("machine-assigned", info)
            unassigned, _total = queue_store.summary(self.queue_dir)
            if unassigned == 0:
                self.log(f"[{self._stamp()}] Queue empty — run `just provision` to add machines")
            else:
                self.log(f"[{self._stamp()}] {unassigned} machine(s) still waiting")
            return "assigned"

        # A machine that failed, or that `just unguard` armed, is starting a
        # new attempt. The elapsed-time rule below can't tell that from a
        # reboot after a finished install, so this is decided first.
        info = read_info(self.queue_dir, mac)
        if info is not None and (info.get("failed_at") or info.get("armed")):
            return self._rearm(mac, current)

        # Within the threshold it's a firmware DHCP retry during the initial
        # PXE. After it, a post-install reboot: install the GRUB guard.
        elapsed = current - first
        if elapsed < REPEAT_PXE_THRESHOLD:
            return "retry"
        # Past the window with no sign the installer ever ran: the boot failed
        # (Secure Boot rejected GRUB, the ISO download died) and the machine
        # is being network-booted again. Machines assigned before installers
        # reported (no `attempt`) keep the rule below.
        if info is not None and "attempt" in info and not self._installer_seen(mac, info):
            return self._boot_failed(mac, info, current)
        wrote = write_guard(self.queue_dir, mac)
        if wrote:
            self.log(f"[{self._stamp()}] Repeat PXE: MAC {mac} ({int(elapsed.total_seconds())}s after first) → GRUB guard installed")
        if info is not None:
            if wrote:
                self._emit("guard-installed", info, reason="repeat-pxe")
            # The first PXE after the window is the post-install reboot. The
            # guard is usually already there from the hostname fetch, so
            # completion is tracked in machine-info.json, stamped before the
            # event so a failed emit can't cause a duplicate later. A failure
            # reported since the read above wins over the completion.
            stamped = []

            def stamp(current_info: dict) -> bool:
                if any(key in current_info for key in ("completed_at", "failed_at", "armed")):
                    return False
                current_info["completed_at"] = current.isoformat(timespec="seconds")
                stamped.append(True)
                return True

            completed = update_info(self.queue_dir, mac, stamp)
            if completed is not None and stamped:
                self.log(f"[{self._stamp()}] Install complete: {completed['name']} ({mac}) rebooted after {int(elapsed.total_seconds())}s")
                self._emit("install-complete", completed, duration_seconds=elapsed.total_seconds())
        return "guard" if wrote else "guard-exists"

    def check_timeouts(self) -> list:
        """Fail PXE installs that have shown no sign of life for the install
        timeout. Returns the names it failed.

        A machine counts as alive from its assignment or last progress report,
        whichever is later. Machines assigned before installers reported
        progress (no `attempt`), finished or already failed installs, ones
        that reported `done`, and ones armed for retry are left alone. USB
        machines have no assignment time to measure from, so only their own
        reports can fail them.
        """
        if not self.install_timeout:
            return []
        now = self.now()
        try:
            entries = queue_store.read(self.queue_dir)
        except (OSError, json.JSONDecodeError):
            return []
        minutes = int(self.install_timeout.total_seconds() // 60)
        failed = []
        for raw in entries:
            mac = raw.get("mac")
            if not (raw.get("assigned") and mac):
                continue
            try:
                info = read_info(self.queue_dir, mac)
                if info is None or "attempt" not in info:
                    continue
                if info.get("completed_at") or info.get("failed_at") or info.get("armed") or info.get("stage") == "done":
                    continue
                activity = last_activity(info)
                if activity is None or now - max(activity, self.started_at) < self.install_timeout:
                    continue
                result = apply_failure(
                    self.queue_dir, name=raw["name"], mac=mac, stage=info.get("stage") or "unknown",
                    reason=f"no installer activity for {minutes} minutes", source="timeout", now=now,
                    emit=self.emit, log=self.log, stale_before=now - self.install_timeout)
            except Exception as e:  # one bad record must not stop the sweep
                self.log(f"[{self._stamp()}] WARNING: timeout check skipped {raw.get('name')}: {e}")
                continue
            if result == "recorded":
                self.log(f"[{self._stamp()}] Install timed out: {raw['name']} ({mac}) silent for {minutes} minutes")
                failed.append(raw["name"])
        return failed

    def _installer_seen(self, mac: str, info: dict) -> bool:
        """Whether this attempt's installer showed any sign of running: a
        progress report, or the hostname fetch that writes the guard."""
        return "stage" in info or "progress_at" in info or (_guard_dir(self.queue_dir) / f"{mac}.cfg").exists()

    def _boot_failed(self, mac: str, info: dict, current: datetime) -> str:
        """Record a boot that never reached the installer, then start a new attempt."""
        apply_failure(
            self.queue_dir, name=info["name"], mac=mac, stage="installer",
            reason="network-booted again before the installer reported anything", source="reboot",
            now=current, emit=self.emit, log=self.log)
        self.log(f"[{self._stamp()}] Boot failed: {info['name']} ({mac}) booted again before the installer ran")
        return self._rearm(mac, current)

    def _rearm(self, mac: str, current: datetime) -> str:
        """Start a new attempt: drop the guard, clear the last attempt's record,
        and restart the retry window from now."""
        remove_guard(self.queue_dir, mac)

        def mutate(info: dict) -> bool:
            for key in RETRY_KEYS:
                info.pop(key, None)
            info["assigned_at"] = current.isoformat(timespec="seconds")
            info["attempt"] = int(info.get("attempt", 1)) + 1
            return True

        info = update_info(self.queue_dir, mac, mutate)
        if info is None:
            return "retry"
        self.log(f"[{self._stamp()}] Retry: MAC {mac} ({info['name']}) starts attempt {info['attempt']}")
        self._emit("machine-assigned", info)
        return "rearmed"

    def on_hostname_fetch(self, mac: str) -> bool:
        """The installer fetched its hostname: the install reached late-commands."""
        refused = []

        def clear_timeout_failure(info: dict) -> bool:
            if not info.get("failed_at"):
                return False
            if info.get("failure_source") != "timeout":
                # The installer itself reported this install failed. A fetch
                # still in flight must not bring the guard back, or the retry
                # would boot an empty disk.
                refused.append(True)
                return False
            for key in INFO_FAILURE_KEYS:  # the timeout guessed wrong
                info.pop(key, None)
            return True

        update_info(self.queue_dir, mac, clear_timeout_failure)
        if refused:
            return False
        wrote = write_guard(self.queue_dir, mac)
        if wrote:
            self.log(f"[{self._stamp()}] Hostname fetched by MAC {mac} → GRUB guard installed")
            info = read_info(self.queue_dir, mac)
            if info is not None:
                self._emit("install-started", info, stage="late-commands")
                self._emit("guard-installed", info, reason="hostname-fetch")
        return wrote


def parse_hostname_fetch(line: str) -> Optional[str]:
    """MAC from a successful hostname fetch in an nginx access-log line, else None."""
    m = HOSTNAME_FETCH_RE.match(line)
    return m.group(1).lower() if m else None


class LogTailer(threading.Thread):
    """Follow a log file like `tail -F`, delivering complete lines to on_line.

    start() opens the file and seeks to its end before the thread runs, so
    history is never replayed unless from_start is set. Truncation (size
    shrinks below the read offset) and replacement (inode changes) call
    on_reopen and reopen the file from the start; a missing file is waited
    for and then read from the start.
    """

    def __init__(self, path: Path, on_line: Callable[[str], None], stop_event: Optional[threading.Event] = None, poll: float = 0.5,
                 from_start: bool = False, on_reopen: Optional[Callable[[], None]] = None):
        super().__init__(name="log-tailer", daemon=True)
        self.path = Path(path)
        self.on_line = on_line
        self.poll = poll
        self.from_start = from_start
        self.on_reopen = on_reopen
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
        self._open(from_end=not self.from_start)
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
                    try:
                        self.on_line(line)
                    except Exception as e:  # one bad line must not end the tailing for good
                        print(f"WARNING: log line handler failed: {e}", file=sys.stderr)
                continue
            if self._rotated():
                self._close()
                if self.on_reopen is not None:
                    self.on_reopen()
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


TIMEOUT_SWEEP_INTERVAL = 30.0


def run_timeout_checks(tracker: PxeTracker, stop_event: threading.Event, interval: float = TIMEOUT_SWEEP_INTERVAL) -> None:
    """Sweep for silent installs until stop_event is set. A failed sweep is logged, never fatal."""
    while not stop_event.wait(interval):
        try:
            tracker.check_timeouts()
        except Exception as e:
            tracker.log(f"WARNING: timeout check failed: {e}")


def watch(interface: Optional[str], queue_dir: Path, access_log: Path, replay: Optional[str] = None,
          events_log: Optional[Path] = None, install_timeout: Optional[timedelta] = None):
    """Sniff DHCP Discover packets via tcpdump (or replay a capture) and assign names."""
    queue_dir = queue_dir.resolve()
    emit = event_journal.EventJournal(events_log, owner_ref=queue_dir).emit if events_log else None
    tracker = PxeTracker(queue_dir, emit=emit, install_timeout=install_timeout)

    try:
        unassigned, total = queue_store.summary(queue_dir)
    except json.JSONDecodeError as e:
        print(f"ERROR: {queue_dir / queue_store.QUEUE_FILE} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"PXE Watcher started on {interface or 'replay'}")
    print(f"  Queue directory: {queue_dir}")
    print(f"  Access log:      {access_log}")
    print(f"  Events log:      {events_log or '(disabled)'}")
    if install_timeout and replay is None:
        print(f"  Install timeout: {int(install_timeout.total_seconds() // 60)} minutes without installer activity")
    else:
        print("  Install timeout: (disabled)")
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

    sweep_stop = threading.Event()

    def stop_threads() -> None:
        tailer.stop()
        sweep_stop.set()

    if install_timeout and replay is None:
        threading.Thread(target=run_timeout_checks, args=(tracker, sweep_stop), name="timeout-sweep", daemon=True).start()

    mac_pattern = re.compile(r"Request from ([0-9a-f:]{17})", re.IGNORECASE)

    def handle_packet(lines: list[str]):
        packet_text = "\n".join(lines)
        if "PXEClient" not in packet_text:
            return
        match = mac_pattern.search(packet_text)
        if not match:
            return
        try:
            tracker.on_pxe(match.group(1).lower())
        except Exception as e:  # one bad machine record must not stop the watcher seeing the rest
            print(f"WARNING: handling PXE request failed: {e}", file=sys.stderr)

    if replay is not None:
        stream = sys.stdin if replay == "-" else open(replay)
        feed_packets(stream, handle_packet)
        stop_threads()
        print_summary(queue_dir)
        return

    # tcpdump with -v shows DHCP options (including Vendor-Class / PXEClient)
    # so we can distinguish PXE boots from regular DHCP traffic.
    cmd = ["tcpdump", "-l", "-n", "-e", "-v", "-i", interface, "udp", "port", "67"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def shutdown(signum, frame):
        stop_threads()
        proc.terminate()
        print("\n")
        print_summary(queue_dir)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    feed_packets(proc.stdout, handle_packet)
    rc = proc.wait()
    err = proc.stderr.read().strip()
    stop_threads()
    print(f"tcpdump exited rc={rc}{': ' + err if err else ''}", file=sys.stderr)
    sys.exit(1)


def detect_interface() -> Optional[str]:
    """The default-route interface, or None if it can't be determined."""
    try:
        if platform.system() == "Darwin":
            result = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True, timeout=5)
            for line in result.stdout.splitlines():
                if "interface:" in line:
                    return line.split()[-1]
        else:
            result = subprocess.run(["ip", "-o", "route", "show", "default"], capture_output=True, text=True, timeout=5)
            parts = result.stdout.split()
            if "dev" in parts:
                return parts[parts.index("dev") + 1]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Watch for PXE boot clients and assign machine names")
    parser.add_argument("--interface", "-i", default=None,
                        help="Network interface to listen on (default: auto-detect from default route)")
    parser.add_argument("--queue-dir", "-q", type=Path, default=repo / "http-server" / "machines",
                        help="Directory containing queue.json and credential slots (default: ../http-server/machines)")
    parser.add_argument("--access-log", type=Path, default=repo / "logs" / "access.log",
                        help="nginx access log to watch for hostname fetches (default: ../logs/access.log)")
    parser.add_argument("--events-log", type=Path, default=repo / "logs" / "events.jsonl",
                        help="JSONL journal of lifecycle events read by the API (default: ../logs/events.jsonl)")
    parser.add_argument("--replay", metavar="FILE",
                        help="Read tcpdump -v output from FILE (or - for stdin) instead of sniffing; no root needed")
    parser.add_argument("--install-timeout-minutes", type=int, default=0, metavar="N",
                        help="Fail an install with no installer activity for N minutes (default: 0, off). "
                             "`just serve` and the launchd daemon pass INSTALL_TIMEOUT_MINUTES from site.env, which defaults to 45.")
    parser.add_argument("--rearm", metavar="MAC",
                        help="Make a machine reinstall on its next PXE boot, then exit; no root needed")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass

    if args.rearm:
        if arm_retry(args.queue_dir.resolve(), args.rearm):
            print(f"{args.rearm} will reinstall on its next PXE boot")
            return
        print(f"ERROR: no machine record for {args.rearm}", file=sys.stderr)
        sys.exit(1)

    if args.replay is not None:
        watch(None, args.queue_dir, args.access_log, replay=args.replay, events_log=args.events_log)
        return

    if os.geteuid() != 0:
        print("ERROR: Must run as root (tcpdump needs raw socket access)", file=sys.stderr)
        print(f"  Try: sudo {' '.join(sys.argv)}", file=sys.stderr)
        sys.exit(1)

    interface = args.interface or detect_interface()
    if interface is None:
        print("ERROR: Could not detect default network interface.", file=sys.stderr)
        print("  Specify one with --interface", file=sys.stderr)
        sys.exit(1)
    install_timeout = timedelta(minutes=args.install_timeout_minutes) if args.install_timeout_minutes > 0 else None
    watch(interface, args.queue_dir, args.access_log, events_log=args.events_log, install_timeout=install_timeout)


if __name__ == "__main__":
    main()
