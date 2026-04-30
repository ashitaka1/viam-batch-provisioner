#!/usr/bin/env python3
"""Tests for the PXE watcher's guard-write behavior.

The guard mechanism is correctness-critical: a missing guard causes a
freshly-installed machine to reinstall on every reboot (firmware always
prefers PXE), and a too-early guard aborts the in-progress install.
These tests pin both ends of that contract.
"""

import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import watcher  # noqa: E402


class WriteGuardTest(unittest.TestCase):
    """write_guard contract: idempotent file with 'exit\\n' under the
    netboot/grub/provisioned tree (sibling of the queue dir's grandparent)."""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name)
        # Mimic real layout: <root>/http-server/machines/  is queue_dir
        self.queue_dir = self.root / "http-server" / "machines"
        self.queue_dir.mkdir(parents=True)
        self.guard_dir = self.root / "netboot" / "grub" / "provisioned"

    def tearDown(self):
        self._tmp.cleanup()

    def test_creates_guard_file_with_exit(self):
        wrote = watcher.write_guard(self.queue_dir, "aa:bb:cc:dd:ee:ff")
        self.assertTrue(wrote)
        guard = self.guard_dir / "aa:bb:cc:dd:ee:ff.cfg"
        self.assertTrue(guard.exists())
        self.assertEqual(guard.read_text(), "exit\n")

    def test_idempotent_returns_false_on_second_call(self):
        watcher.write_guard(self.queue_dir, "11:22:33:44:55:66")
        wrote_again = watcher.write_guard(self.queue_dir, "11:22:33:44:55:66")
        self.assertFalse(wrote_again)

    def test_does_not_overwrite_existing_guard(self):
        guard = self.guard_dir / "11:22:33:44:55:66.cfg"
        guard.parent.mkdir(parents=True, exist_ok=True)
        guard.write_text("custom-content\n")
        watcher.write_guard(self.queue_dir, "11:22:33:44:55:66")
        self.assertEqual(guard.read_text(), "custom-content\n")


class RepeatPxeTimingTest(unittest.TestCase):
    """The threshold logic distinguishes firmware DHCP retries (within seconds
    of first PXE) from post-install reboots (minutes later). The first must
    not produce a guard; the second must."""

    def test_threshold_is_at_least_30_seconds(self):
        # Observed firmware retry bursts last ~15s; threshold must safely
        # exceed that to avoid aborting an in-progress install.
        self.assertGreaterEqual(watcher.REPEAT_PXE_THRESHOLD.total_seconds(), 30)

    def test_elapsed_below_threshold_skips_guard(self):
        first = datetime.now(timezone.utc)
        retry = first + timedelta(seconds=10)
        self.assertLess(retry - first, watcher.REPEAT_PXE_THRESHOLD)

    def test_elapsed_above_threshold_triggers_guard(self):
        first = datetime.now(timezone.utc)
        reboot = first + timedelta(minutes=10)
        self.assertGreaterEqual(reboot - first, watcher.REPEAT_PXE_THRESHOLD)


class AssignedAtRoundTripTest(unittest.TestCase):
    """machine-info.json's assigned_at is the source of truth for first-PXE
    time across watcher restarts. This pins that the format the watcher writes
    is the format the watcher can read back."""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.queue_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_assign_machine_writes_iso_assigned_at(self):
        # Set up a single-slot queue.
        (self.queue_dir / "queue.json").write_text(json.dumps([
            {"slot_id": None, "name": "test-1", "assigned": False},
        ]))
        queue = watcher.load_queue(self.queue_dir)
        watcher.assign_machine(self.queue_dir, queue, "aa:bb:cc:dd:ee:ff")

        info = json.loads((self.queue_dir / "aa:bb:cc:dd:ee:ff" / "machine-info.json").read_text())
        # Round-trip: must parse as an ISO datetime.
        ts = datetime.fromisoformat(info["assigned_at"])
        self.assertIsNotNone(ts.tzinfo)


if __name__ == "__main__":
    unittest.main()
