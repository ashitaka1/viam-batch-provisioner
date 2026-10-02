#!/usr/bin/env python3
"""The single writer of http-server/machines/queue.json.

queue.json is a JSON array of entries:
    {"name": "lab-7", "assigned": false}                       os-only / agent
    {"name": "lab-7", "slot_id": "slot-lab-7", "assigned": false}   full mode
Assignment adds "mac"; USB flashing adds "flashed_via".

The watcher daemon (root) and the operator's scripts (user) both write this
file, so every mutation takes an flock on queue.lock and replaces the file
atomically. Files created here take the owner of the queue directory, so a
root daemon never leaves files the operator can't modify.

Also a CLI for the bash scripts:
    queue_store.py append [--queue-dir DIR]          entries JSON on stdin
    queue_store.py next-index --prefix P
    queue_store.py has-name --name N                 exit 0 if present, 1 if not
    queue_store.py mark-assigned --name N [--via usb]
    queue_store.py reset
    queue_store.py summary                           prints "<unassigned> <total>"
    queue_store.py list
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Generator, Optional

QUEUE_FILE = "queue.json"
LOCK_FILE = "queue.lock"
TEMP_PREFIX = ".queue.json."

DEFAULT_QUEUE_DIR = Path(__file__).resolve().parent.parent / "http-server" / "machines"


def chown_like(path: Path, template: Path) -> None:
    """Give path the owner of template. No-op unless running as root."""
    if os.geteuid() != 0:
        return
    st = template.stat()
    os.chown(path, st.st_uid, st.st_gid)


@contextmanager
def locked(queue_dir: Path, timeout: Optional[float] = 30.0) -> Generator[None, None, None]:
    """Hold an exclusive flock on queue_dir/queue.lock.

    Opens a fresh descriptor per call so two callers in one process still
    exclude each other. Raises TimeoutError if the lock isn't acquired
    within timeout seconds (None waits forever).
    """
    queue_dir.mkdir(parents=True, exist_ok=True)
    lock_path = queue_dir / LOCK_FILE
    existed = lock_path.exists()
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        if not existed:
            try:
                os.chmod(lock_path, 0o666)
                chown_like(lock_path, queue_dir)
            except OSError:
                pass
        if timeout is None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        else:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"could not lock {lock_path} within {timeout}s")
                    time.sleep(0.01)
        yield
    finally:
        os.close(fd)


def read(queue_dir: Path) -> list[dict]:
    """Return the queue, or [] if the file doesn't exist. Invalid JSON raises."""
    path = queue_dir / QUEUE_FILE
    if not path.exists():
        return []
    with open(path) as f:
        return json.load(f)


def write(queue_dir: Path, entries: list[dict]) -> None:
    """Replace queue.json atomically."""
    queue_dir.mkdir(parents=True, exist_ok=True)
    path = queue_dir / QUEUE_FILE
    fd, tmp = tempfile.mkstemp(prefix=TEMP_PREFIX, dir=str(queue_dir))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(entries, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        chown_like(Path(tmp), queue_dir)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def append(queue_dir: Path, new_entries: list[dict]) -> tuple[list[dict], list[str]]:
    """Add entries whose names aren't already queued.

    Returns (added entries, skipped names). Does not touch the file when
    nothing is added.
    """
    if not new_entries:
        return [], []
    with locked(queue_dir):
        entries = read(queue_dir)
        names = {e["name"] for e in entries}
        added: list[dict] = []
        skipped: list[str] = []
        for e in new_entries:
            if e["name"] in names:
                skipped.append(e["name"])
                continue
            names.add(e["name"])
            added.append(e)
        if added:
            write(queue_dir, entries + added)
    return added, skipped


def assign_next(queue_dir: Path, mac: str) -> Optional[dict]:
    """Mark the first unassigned entry as assigned to mac and return a copy of it."""
    with locked(queue_dir):
        entries = read(queue_dir)
        for e in entries:
            if not e.get("assigned"):
                e["assigned"] = True
                e["mac"] = mac
                write(queue_dir, entries)
                return dict(e)
    return None


def mark_assigned(queue_dir: Path, name: str, **extra) -> bool:
    """Mark the named entry assigned, setting any extra keys. False if absent."""
    with locked(queue_dir):
        entries = read(queue_dir)
        for e in entries:
            if e["name"] == name:
                e["assigned"] = True
                e.update(extra)
                write(queue_dir, entries)
                return True
    return False


def reset(queue_dir: Path) -> int:
    """Mark every entry unassigned. Returns the number of entries."""
    with locked(queue_dir):
        entries = read(queue_dir)
        for e in entries:
            e["assigned"] = False
            e["mac"] = None
            e.pop("flashed_via", None)
        if entries:
            write(queue_dir, entries)
    return len(entries)


def next_index(queue_dir: Path, prefix: str) -> int:
    """1 + the highest N among names of the form <prefix>-N; 1 if none."""
    pattern = re.compile(rf"^{re.escape(prefix)}-(\d+)$")
    highest = 0
    for e in read(queue_dir):
        m = pattern.match(e.get("name", ""))
        if m:
            highest = max(highest, int(m.group(1)))
    return highest + 1


def summary(queue_dir: Path) -> tuple[int, int]:
    """(unassigned, total)."""
    entries = read(queue_dir)
    return sum(1 for e in entries if not e.get("assigned")), len(entries)


def format_list(entries: list[dict]) -> str:
    lines = []
    for e in entries:
        mark = "✓" if e.get("assigned") else "○"
        where = e.get("mac") or ("usb" if e.get("flashed_via") == "usb" else "waiting...")
        lines.append(f"  {mark} {e['name']:<25} {where}")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--queue-dir", type=Path, default=DEFAULT_QUEUE_DIR)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("append", parents=[common])
    p = sub.add_parser("next-index", parents=[common])
    p.add_argument("--prefix", required=True)
    p = sub.add_parser("has-name", parents=[common])
    p.add_argument("--name", required=True)
    p = sub.add_parser("mark-assigned", parents=[common])
    p.add_argument("--name", required=True)
    p.add_argument("--via")
    sub.add_parser("reset", parents=[common])
    sub.add_parser("summary", parents=[common])
    sub.add_parser("list", parents=[common])
    args = parser.parse_args(argv)
    queue_dir: Path = args.queue_dir

    if args.cmd == "append":
        entries = json.load(sys.stdin)
        added, _skipped = append(queue_dir, entries)
        added_names = {e["name"] for e in added}
        seen: set[str] = set()
        for e in entries:
            name = e["name"]
            if name in added_names and name not in seen:
                print(f"added {name}")
            else:
                print(f"skipped {name}")
            seen.add(name)
        return 0
    if args.cmd == "next-index":
        print(next_index(queue_dir, args.prefix))
        return 0
    if args.cmd == "has-name":
        return 0 if any(e["name"] == args.name for e in read(queue_dir)) else 1
    if args.cmd == "mark-assigned":
        extra = {"flashed_via": args.via} if args.via else {}
        if mark_assigned(queue_dir, args.name, **extra):
            return 0
        print(f"{args.name} not in queue", file=sys.stderr)
        return 1
    if args.cmd == "reset":
        print(f"Reset {reset(queue_dir)} entries")
        return 0
    if args.cmd == "summary":
        unassigned, total = summary(queue_dir)
        print(f"{unassigned} {total}")
        return 0
    if args.cmd == "list":
        entries = read(queue_dir)
        if not entries:
            print("  No queue. Run 'just provision' first.")
        else:
            print(format_list(entries))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
