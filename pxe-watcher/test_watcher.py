#!/usr/bin/env python3
"""Tests for the PXE watcher's assignment and guard behavior.

The guard mechanism is correctness-critical: a missing guard causes a
freshly-installed machine to reinstall on every reboot (firmware always
prefers PXE), and a too-early guard aborts the in-progress install. The
watcher keeps no state in memory, so operator actions on disk (provision,
reset, clean) take effect on the running daemon.
"""

import json
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import watcher  # noqa: E402

MAC = "aa:bb:cc:dd:ee:ff"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)


def wait_until(pred, timeout=5.0, interval=0.01):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return pred()


class RepoLayoutTest(unittest.TestCase):
    """Mimics the real layout: <root>/http-server/machines is the queue dir,
    <root>/netboot/grub/provisioned holds the guards."""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.queue_dir = self.root / "http-server" / "machines"
        self.queue_dir.mkdir(parents=True)
        self.guard_dir = self.root / "netboot" / "grub" / "provisioned"

    def tearDown(self):
        self._tmp.cleanup()

    def seed(self, entries):
        (self.queue_dir / "queue.json").write_text(json.dumps(entries, indent=2))

    def guard(self, mac=MAC):
        return self.guard_dir / f"{mac}.cfg"


class WriteGuardTest(RepoLayoutTest):
    def test_creates_guard_file_with_exit(self):
        self.assertTrue(watcher.write_guard(self.queue_dir, MAC))
        self.assertEqual(self.guard().read_text(), "exit\n")

    def test_idempotent_returns_false_on_second_call(self):
        watcher.write_guard(self.queue_dir, "11:22:33:44:55:66")
        self.assertFalse(watcher.write_guard(self.queue_dir, "11:22:33:44:55:66"))

    def test_does_not_overwrite_existing_guard(self):
        guard = self.guard("11:22:33:44:55:66")
        guard.parent.mkdir(parents=True, exist_ok=True)
        guard.write_text("custom-content\n")
        watcher.write_guard(self.queue_dir, "11:22:33:44:55:66")
        self.assertEqual(guard.read_text(), "custom-content\n")


class PxeTrackerTest(RepoLayoutTest):
    def setUp(self):
        super().setUp()
        self.clock = T0
        self.tracker = watcher.PxeTracker(self.queue_dir, now=lambda: self.clock, log=lambda *_: None)

    def advance(self, seconds):
        self.clock = T0 + timedelta(seconds=seconds)

    def test_assigns_then_ignores_retry_then_guards_after_window(self):
        self.seed([{"name": "t-1", "assigned": False}])

        result = self.tracker.on_pxe(MAC)
        machine_dir = self.queue_dir / MAC
        self.assertEqual((machine_dir / "hostname").read_text(), "t-1")
        info = json.loads((machine_dir / "machine-info.json").read_text())
        self.assertEqual(info["name"], "t-1")
        self.assertEqual(info["mac"], MAC)
        self.assertEqual(datetime.fromisoformat(info["assigned_at"]), T0)
        self.assertFalse(self.guard().exists())
        self.assertEqual(result, "assigned")

        self.advance(59)
        result = self.tracker.on_pxe(MAC)
        self.assertFalse(self.guard().exists())
        self.assertEqual(result, "retry")

        self.advance(61)
        result = self.tracker.on_pxe(MAC)
        self.assertEqual(self.guard().read_text(), "exit\n")
        self.assertEqual(result, "guard")

    def test_copies_slot_credentials_when_present(self):
        slot = self.queue_dir / "slot-t-1"
        slot.mkdir()
        (slot / "viam.json").write_text('{"cloud": "creds"}')
        self.seed([{"name": "t-1", "slot_id": "slot-t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.assertEqual((self.queue_dir / MAC / "viam.json").read_text(), '{"cloud": "creds"}')

    def test_no_slot_leaves_no_trace_and_never_guards(self):
        self.seed([])
        result = self.tracker.on_pxe(MAC)
        self.assertFalse((self.queue_dir / MAC).exists())
        self.assertEqual(result, "no-slot")
        self.advance(61)
        result = self.tracker.on_pxe(MAC)
        self.assertFalse(self.guard().exists())
        self.assertFalse((self.queue_dir / MAC).exists())
        self.assertEqual(result, "no-slot")

    def test_assigns_after_queue_is_provisioned_later(self):
        self.seed([])
        self.tracker.on_pxe(MAC)
        self.seed([{"name": "t-1", "assigned": False}])
        self.advance(120)
        result = self.tracker.on_pxe(MAC)
        self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-1")
        self.assertEqual(result, "assigned")

    def test_reset_on_disk_makes_mac_assignable_again(self):
        self.seed([{"name": "t-1", "assigned": False}, {"name": "t-2", "assigned": False}])
        self.tracker.on_pxe(MAC)
        # What `just reset` does to a MAC: remove its directory.
        for p in (self.queue_dir / MAC).iterdir():
            p.unlink()
        (self.queue_dir / MAC).rmdir()
        self.advance(600)
        result = self.tracker.on_pxe(MAC)
        self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-2")
        self.assertEqual(result, "assigned")

    def test_hostname_fetch_writes_guard_once(self):
        self.assertTrue(self.tracker.on_hostname_fetch(MAC))
        self.assertEqual(self.guard().read_text(), "exit\n")
        self.assertFalse(self.tracker.on_hostname_fetch(MAC))


class ParseHostnameFetchTest(unittest.TestCase):
    LINE = '10.1.0.42 - - [22/Apr/2026:13:24:58 -0400] "{req}" {status} 7 "{ref}" "{ua}" "-"'

    def line(self, req, status=200, ref="-", ua="curl/8.5.0"):
        return self.LINE.format(req=req, status=status, ref=ref, ua=ua)

    def test_hostname_fetch_returns_lowercase_mac(self):
        line = self.line("GET /machines/AA:BB:CC:DD:EE:FF/hostname HTTP/1.1")
        self.assertEqual(watcher.parse_hostname_fetch(line), MAC)

    def test_non_matching_requests_return_none(self):
        cases = {
            "404": self.line(f"GET /machines/{MAC}/hostname HTTP/1.1", status=404),
            "viam.json": self.line(f"GET /machines/{MAC}/viam.json HTTP/1.1"),
            "by-name": self.line("GET /machines/by-name/lab-7/hostname HTTP/1.1"),
            "HEAD": self.line(f"HEAD /machines/{MAC}/hostname HTTP/1.1"),
            "POST": self.line(f"POST /machines/{MAC}/hostname HTTP/1.1"),
            # A query string is not the plain hostname fetch the installer makes.
            "query": self.line(f"GET /machines/{MAC}/hostname?x=1 HTTP/1.1"),
            "empty": "",
            "garbage": "nginx: [notice] start worker processes",
            "referer-only": self.line("GET /autoinstall/user-data HTTP/1.1",
                                      ref=f"http://x/machines/{MAC}/hostname"),
            "ua-only": self.line("GET /autoinstall/user-data HTTP/1.1",
                                 ua=f"GET /machines/{MAC}/hostname HTTP/1.1 200"),
        }
        for label, line in cases.items():
            with self.subTest(label):
                self.assertIsNone(watcher.parse_hostname_fetch(line))


class LogTailerTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.path = Path(self._tmp.name) / "access.log"
        self.received = []
        self.tailer = None

    def tearDown(self):
        if self.tailer is not None:
            self.tailer.stop()
            self.tailer.join(timeout=5)
        self._tmp.cleanup()

    def start(self):
        self.tailer = watcher.LogTailer(self.path, self.received.append, poll=0.02)
        self.tailer.start()
        self.assertTrue(self.tailer.ready.wait(5), "tailer never became ready")

    def append(self, text):
        with open(self.path, "a") as f:
            f.write(text)
            f.flush()

    def expect(self, lines):
        ok = wait_until(lambda: self.received == lines)
        self.assertTrue(ok, f"expected {lines!r}, received {self.received!r}")

    def test_does_not_replay_existing_lines(self):
        self.path.write_text("old line one is fairly long\nold line two is fairly long\n")
        self.start()
        self.append("sentinel\n")
        self.expect(["sentinel"])

    def test_follows_through_truncation(self):
        self.path.write_text("old line one is fairly long\nold line two is fairly long\n")
        self.start()
        self.append("sentinel line that is long enough\n")
        self.expect(["sentinel line that is long enough"])
        # Truncate and write less than the offset we had read to.
        self.path.write_text("")
        self.append("T1\n")
        self.expect(["sentinel line that is long enough", "T1"])

    def test_follows_through_delete_and_recreate_from_start(self):
        self.path.write_text("old\n")
        self.start()
        self.append("sentinel\n")
        self.expect(["sentinel"])
        self.path.unlink()
        # Longer than the offset we had read to, so only the inode change
        # (not a size shrink) can reveal the replacement.
        with open(self.path, "w") as f:
            f.write("new-1\nnew-2\nnew-3 is a longer line\n")
        self.expect(["sentinel", "new-1", "new-2", "new-3 is a longer line"])

    def test_waits_for_missing_file_then_reads_from_start(self):
        self.assertFalse(self.path.exists())
        self.start()
        with open(self.path, "w") as f:
            f.write("first\n")
        self.expect(["first"])

    def test_partial_line_waits_for_newline(self):
        self.path.write_text("")
        self.start()
        self.append("part")
        self.append("x\n")  # still one line
        self.expect(["partx"])
        self.append("tail-no-newline")
        time.sleep(0.1)  # deliberate negative window: several polls, nothing delivered
        self.assertEqual(self.received, ["partx"])
        self.append("\n")
        self.expect(["partx", "tail-no-newline"])


if __name__ == "__main__":
    unittest.main()
