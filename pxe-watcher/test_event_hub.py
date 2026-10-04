"""Tests for the API-side event hub that tails the journal.

The hub decides what an SSE client with a given cursor receives: the exact
events after it, or a resync when the gap cannot be served.
"""

import sys
import threading
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_hub  # noqa: E402
import event_journal  # noqa: E402

MAC = "aa:bb:cc:dd:ee:ff"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)


def wait_until(pred, timeout=5.0, interval=0.01):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return pred()


class HubTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        logs = Path(self._tmp.name) / "logs"
        logs.mkdir()
        self.path = logs / "events.jsonl"
        self.journal = event_journal.EventJournal(self.path, now=lambda: T0)
        self.hubs = []

    def tearDown(self):
        for hub in self.hubs:
            hub.stop()
        self._tmp.cleanup()

    def emit(self, count=1):
        return [self.journal.emit("machine-assigned", {"name": f"t-{i}", "mac": MAC}) for i in range(count)]

    def start_hub(self, ring_size=1000):
        hub = event_hub.EventHub(self.path, ring_size=ring_size, poll=0.02)
        hub.start()
        self.hubs.append(hub)
        return hub

    def test_events_after_cursor_and_resync(self):
        records = self.emit(5)
        hub = self.start_hub(ring_size=3)
        self.assertEqual(hub.last_id, 5, "hub must load the existing journal before serving")

        cases = [
            (4, ("ok", records[4:])),
            (2, ("ok", records[2:])),
            (5, ("ok", [])),
            (7, ("resync", 5)),
            (1, ("resync", 5)),
        ]
        for cursor, expected in cases:
            with self.subTest(cursor=cursor):
                self.assertEqual(hub.events_after(cursor), expected, f"cursor={cursor}")

    def test_truncation_clears_ring_keeps_last_id(self):
        self.emit(3)
        hub = self.start_hub()
        self.assertEqual(hub.events_after(0)[0], "ok")

        self.path.write_text("")
        self.assertTrue(wait_until(lambda: hub.events_after(0) == ("resync", 3)), hub.events_after(0))
        self.assertEqual(hub.last_id, 3)

        fresh = event_journal.EventJournal(self.path, now=lambda: T0).emit("machine-assigned", {"name": "n", "mac": MAC})
        self.assertEqual(fresh["id"], 1)
        self.assertTrue(wait_until(lambda: hub.events_after(0) == ("ok", [fresh])), hub.events_after(0))
        self.assertEqual(hub.last_id, 1)

    def test_wait_returns_immediately_when_behind(self):
        self.emit(2)
        hub = self.start_hub()
        started = time.monotonic()
        self.assertTrue(hub.wait(1, timeout=0))
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertFalse(hub.wait(2, timeout=0))
        self.assertEqual(hub.events_after(1), ("ok", [r for r in self._all() if r["id"] == 2]))

    def _all(self):
        return [event_journal.parse_line(line) for line in self.path.read_text().splitlines()]

    def test_wait_wakes_on_event_and_on_stop(self):
        hub = self.start_hub()
        results = []

        waiter = threading.Thread(target=lambda: results.append(hub.wait(0, timeout=5)))
        waiter.start()
        time.sleep(0.05)
        self.emit(1)
        waiter.join(2)
        self.assertFalse(waiter.is_alive(), "wait() did not wake on a new event")
        self.assertEqual(results, [True])

        results.clear()
        waiter = threading.Thread(target=lambda: results.append(hub.wait(hub.last_id, timeout=5)))
        waiter.start()
        time.sleep(0.05)
        hub.stop()
        waiter.join(2)
        self.assertFalse(waiter.is_alive(), "wait() did not wake on stop()")
        self.assertEqual(results, [False])

    def test_skips_malformed_line(self):
        first = self.emit(1)[0]
        with open(self.path, "a") as f:
            f.write("not json at all\n")
        second = self.emit(1)[0]
        hub = self.start_hub()
        self.assertEqual(hub.events_after(0), ("ok", [first, second]))


if __name__ == "__main__":
    unittest.main()
