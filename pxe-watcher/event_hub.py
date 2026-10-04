#!/usr/bin/env python3
"""In-memory view of the event journal for the API process.

Tails logs/events.jsonl from the start, keeps the most recent records in a
ring, and answers "what does a client with cursor N get next": the records
after N, or a resync when N is ahead of the journal or older than the ring.
"""

from __future__ import annotations

import sys
import threading
from collections import deque
from pathlib import Path
from typing import Any, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_journal  # noqa: E402
from watcher import LogTailer  # noqa: E402


class EventHub:
    def __init__(self, journal_path: Path, ring_size: int = 1000, poll: float = 0.2):
        self.path = Path(journal_path)
        self._ring: deque = deque(maxlen=ring_size)
        self._cond = threading.Condition()
        self._last_id = 0
        self.stopped = False
        self._tailer = LogTailer(self.path, self._on_line, poll=poll, from_start=True, on_reopen=self._on_reopen)

    @property
    def last_id(self) -> int:
        with self._cond:
            return self._last_id

    def start(self, timeout: float = 2.0) -> None:
        """Start tailing and wait until the journal already on disk is loaded."""
        records = event_journal.read_all(self.path)
        target = records[-1]["id"] if records else 0
        self._tailer.start()
        with self._cond:
            if not self._cond.wait_for(lambda: self._last_id >= target, timeout):
                print(f"WARNING: event journal not fully loaded after {timeout}s", file=sys.stderr)

    def stop(self) -> None:
        with self._cond:
            self.stopped = True
            self._cond.notify_all()
        self._tailer.stop()

    def _on_line(self, line: str) -> None:
        record = event_journal.parse_line(line)
        if record is None:
            return
        with self._cond:
            self._ring.append(record)
            self._last_id = record["id"]
            self._cond.notify_all()

    def _on_reopen(self) -> None:
        with self._cond:
            self._ring.clear()

    def events_after(self, cursor: int) -> Tuple[str, Any]:
        """("ok", [records with id > cursor]) or ("resync", latest_id)."""
        with self._cond:
            if cursor > self._last_id:
                return "resync", self._last_id
            if cursor == self._last_id:
                return "ok", []
            if not self._ring or self._ring[0]["id"] > cursor + 1:
                return "resync", self._last_id
            return "ok", [r for r in self._ring if r["id"] > cursor]

    def wait(self, cursor: int, timeout: float) -> bool:
        """Block until last_id differs from cursor or the hub stops.

        True means events_after(cursor) has something to say (new records, or
        a resync after a journal reset). False means the hub stopped or the
        timeout passed with nothing new.
        """
        with self._cond:
            if self.stopped:
                return False
            if self._last_id != cursor:
                return True
            self._cond.wait_for(lambda: self.stopped or self._last_id != cursor, timeout)
            return (not self.stopped) and self._last_id != cursor
