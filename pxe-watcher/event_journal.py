#!/usr/bin/env python3
"""Append-only journal of machine lifecycle events, written by the watcher.

One JSON object per line:

    {"id": 12, "type": "guard-installed",
     "data": {"id": 12, "type": "guard-installed", "timestamp": "...",
              "name": "lab-7", "mac": "aa:...", "reason": "repeat-pxe"}}

`data` is exactly the SSE payload the API serves. Ids are derived from the
last complete line on disk under an flock, so they stay monotonic across
process restarts without any in-memory counter. Files take the owner of the
journal's directory so a root writer never leaves files the operator can't
read or truncate.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import queue_store  # noqa: E402

LOCK_SUFFIX = ".lock"
TAIL_BYTES = 8192


def parse_line(line: str) -> Optional[dict]:
    """The record on a journal line, or None if it is torn or not a record."""
    try:
        record = json.loads(line)
    except ValueError:
        return None
    if not isinstance(record, dict) or not isinstance(record.get("id"), int) or "type" not in record or "data" not in record:
        return None
    return record


def read_all(path: Path) -> list:
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        record = parse_line(line)
        if record is not None:
            records.append(record)
    return records


class EventJournal:
    def __init__(self, path: Path, owner_ref: Optional[Path] = None, now: Optional[Callable[[], datetime]] = None):
        self.path = Path(path)
        self.lock_path = self.path.with_suffix(LOCK_SUFFIX)
        self.owner_ref = Path(owner_ref) if owner_ref else self.path.parent
        self.now = now or (lambda: datetime.now(timezone.utc))

    def emit(self, type: str, data: dict) -> dict:
        """Append one event and return the full record."""
        with queue_store.locked_file(self.lock_path, self.owner_ref, timeout=None):
            existed = self.path.exists()
            last_id, needs_newline = self._tail_state()
            record_id = last_id + 1
            payload = dict(data)
            payload.update({"id": record_id, "type": type, "timestamp": self.now().isoformat(timespec="seconds")})
            record = {"id": record_id, "type": type, "data": payload}
            line = ("\n" if needs_newline else "") + json.dumps(record, separators=(",", ":")) + "\n"
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                os.write(fd, line.encode())
                os.fsync(fd)
            finally:
                os.close(fd)
            if not existed:
                try:
                    os.chmod(self.path, 0o644)
                    queue_store.chown_like(self.path, self.owner_ref)
                except OSError:
                    pass
            return record

    def _tail_state(self):
        """(id of the last complete record, whether the file ends mid-line)."""
        try:
            size = self.path.stat().st_size
        except FileNotFoundError:
            return 0, False
        if size == 0:
            return 0, False
        with open(self.path, "rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            tail = f.read()
        needs_newline = not tail.endswith(b"\n")
        lines = tail.decode("utf-8", errors="replace").splitlines()
        if size > TAIL_BYTES and lines:
            lines = lines[1:]  # the first chunk line may be a fragment
        for line in reversed(lines):
            record = parse_line(line)
            if record is not None:
                return record["id"], needs_newline
        if size > TAIL_BYTES:
            # No complete record in the tail window; scan the whole file.
            records = read_all(self.path)
            return (records[-1]["id"] if records else 0), needs_newline
        return 0, needs_newline
