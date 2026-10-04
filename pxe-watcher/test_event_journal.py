"""Tests for the append-only event journal the watcher writes.

Event ids are the SSE Last-Event-ID contract: they must be monotonic without
any in-memory counter, survive a torn write, and stay unique under
concurrent emitters.
"""

import json
import sys
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_journal  # noqa: E402

MAC = "aa:bb:cc:dd:ee:ff"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)


class JournalTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        logs = Path(self._tmp.name) / "logs"
        logs.mkdir()
        self.path = logs / "events.jsonl"

    def tearDown(self):
        self._tmp.cleanup()

    def journal(self):
        return event_journal.EventJournal(self.path, now=lambda: T0)

    def records(self):
        return [json.loads(line) for line in self.path.read_text().splitlines()]

    def test_ids_continue_across_instances(self):
        first = self.journal()
        first.emit("machine-assigned", {"name": "t-1", "mac": MAC})
        first.emit("install-started", {"name": "t-1", "mac": MAC, "stage": "late-commands"})
        second = self.journal()
        second.emit("guard-installed", {"name": "t-1", "mac": MAC, "reason": "hostname-fetch"})
        last = second.emit("install-complete", {"name": "t-1", "mac": MAC, "duration_seconds": 5})

        self.assertEqual([r["id"] for r in self.records()], [1, 2, 3, 4])
        self.assertEqual(last["id"], 4)
        head = self.records()[0]
        self.assertEqual(head["type"], "machine-assigned")
        self.assertEqual(head["data"]["id"], 1)
        self.assertEqual(head["data"]["type"], "machine-assigned")
        self.assertEqual(head["data"]["timestamp"], T0.isoformat())
        self.assertEqual(head["data"]["name"], "t-1")

    def test_repairs_torn_trailing_line(self):
        journal = self.journal()
        journal.emit("machine-assigned", {"name": "t-1", "mac": MAC})
        journal.emit("machine-assigned", {"name": "t-2", "mac": MAC})
        with open(self.path, "a") as f:
            f.write('{"id": 3, "type": "machine-assigned", "da')

        record = journal.emit("machine-assigned", {"name": "t-3", "mac": MAC})

        self.assertEqual(record["id"], 3, "torn fragment must not count as id 3")
        lines = self.path.read_text().splitlines()
        self.assertEqual(len(lines), 4, lines)
        self.assertIsNone(event_journal.parse_line(lines[2]))
        self.assertEqual(json.loads(lines[3])["id"], 3)
        self.assertEqual(json.loads(lines[3])["data"]["name"], "t-3")

    def test_concurrent_emits_are_unique_and_contiguous(self):
        barrier = threading.Barrier(8)

        def worker():
            journal = self.journal()
            barrier.wait()
            for _ in range(5):
                journal.emit("machine-assigned", {"name": "t", "mac": MAC})

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)
            self.assertFalse(t.is_alive(), "emitter thread hung")

        records = self.records()
        self.assertEqual(sorted(r["id"] for r in records), list(range(1, 41)))
        self.assertTrue(all(event_journal.parse_line(json.dumps(r)) for r in records))


if __name__ == "__main__":
    unittest.main()
