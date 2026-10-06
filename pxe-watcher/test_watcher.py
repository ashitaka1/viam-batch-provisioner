#!/usr/bin/env python3
"""Tests for the PXE watcher's assignment and guard behavior.

The guard mechanism is correctness-critical: a missing guard causes a
freshly-installed machine to reinstall on every reboot (firmware always
prefers PXE), and a too-early guard aborts the in-progress install. The
watcher keeps no state in memory, so operator actions on disk (provision,
reset, clean) take effect on the running daemon.
"""

import json
import shutil
import sys
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import queue_store  # noqa: E402
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
        # What `just reset` does: mark every entry unassigned and remove the
        # MAC directories.
        queue_store.reset(self.queue_dir)
        for p in (self.queue_dir / MAC).iterdir():
            p.unlink()
        (self.queue_dir / MAC).rmdir()
        self.advance(600)
        result = self.tracker.on_pxe(MAC)
        self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-1")
        self.assertEqual(result, "assigned")

    def test_mac_dir_removed_but_entry_still_assigned_is_completed_not_duplicated(self):
        self.seed([{"name": "t-1", "assigned": False}, {"name": "t-2", "assigned": False}])
        self.tracker.on_pxe(MAC)
        for p in (self.queue_dir / MAC).iterdir():
            p.unlink()
        (self.queue_dir / MAC).rmdir()
        self.advance(600)
        self.assertEqual(self.tracker.on_pxe(MAC), "assigned")
        self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-1")
        self.assertFalse(queue_store.read(self.queue_dir)[1]["assigned"])

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


class LogTailerFlagsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.path = Path(self._tmp.name) / "events.jsonl"
        self.tailers = []

    def tearDown(self):
        for tailer in self.tailers:
            tailer.stop()
            tailer.join(timeout=5)
        self._tmp.cleanup()

    def start(self, on_line, **kwargs):
        tailer = watcher.LogTailer(self.path, on_line, poll=0.02, **kwargs)
        tailer.start()
        self.tailers.append(tailer)
        return tailer

    def append(self, text):
        with open(self.path, "a") as f:
            f.write(text)

    def test_from_start_delivers_existing_lines(self):
        self.path.write_text("a\nb\n")
        received = []
        self.start(received.append, from_start=True)
        self.assertTrue(wait_until(lambda: received == ["a", "b"]), received)

        default = []
        self.start(default.append, from_start=False)
        self.append("c\n")
        self.assertTrue(wait_until(lambda: default == ["c"]), default)

    def test_on_reopen_fires_on_truncation(self):
        self.path.write_text("old line that is long enough\n")
        events = []
        self.start(events.append, on_reopen=lambda: events.append("<reopen>"))
        self.append("x\n")
        self.assertTrue(wait_until(lambda: events == ["x"]), events)

        self.path.write_text("y\n")
        self.assertTrue(wait_until(lambda: "y" in events), events)
        self.assertEqual(events, ["x", "<reopen>", "y"])


class EmitTest(RepoLayoutTest):
    """Lifecycle events the tracker emits for the API's journal."""

    def setUp(self):
        super().setUp()
        self.clock = T0
        self.events = []
        self.logs = []
        self.tracker = watcher.PxeTracker(
            self.queue_dir, now=lambda: self.clock, log=self.logs.append,
            emit=lambda t, d: self.events.append((t, d)),
        )

    def advance(self, seconds):
        self.clock = T0 + timedelta(seconds=seconds)

    def types(self):
        return [t for t, _ in self.events]

    def info(self, mac=MAC):
        return json.loads((self.queue_dir / mac / "machine-info.json").read_text())

    def write_info(self, info, mac=MAC):
        (self.queue_dir / mac / "machine-info.json").write_text(json.dumps(info))

    def base(self, **extra):
        data = {"name": "t-1", "mac": MAC, "timestamp": self.clock.isoformat()}
        data.update(extra)
        return data

    def install(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.tracker.on_hostname_fetch(MAC)
        self.advance(300)
        self.tracker.on_pxe(MAC)

    def test_emits_machine_assigned_with_clock_timestamp(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.assertEqual(self.events, [("machine-assigned", self.base())])

        self.advance(10)
        self.assertEqual(self.tracker.on_pxe(MAC), "retry")
        self.assertEqual(self.tracker.on_pxe("11:22:33:44:55:66"), "no-slot")
        self.assertEqual(len(self.events), 1, self.events)

    def test_hostname_fetch_emits_started_then_guard_once(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.events.clear()

        self.assertTrue(self.tracker.on_hostname_fetch(MAC))
        self.assertEqual(self.events, [
            ("install-started", self.base(stage="late-commands")),
            ("guard-installed", self.base(reason="hostname-fetch")),
        ])

        self.assertFalse(self.tracker.on_hostname_fetch(MAC))
        self.assertEqual(len(self.events), 2, self.events)

    def test_repeat_pxe_after_hostname_guard_emits_complete_once(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.tracker.on_hostname_fetch(MAC)
        self.events.clear()

        self.advance(300)
        self.assertEqual(self.tracker.on_pxe(MAC), "guard-exists")
        self.assertEqual(self.events, [("install-complete", self.base(duration_seconds=300.0))])
        self.assertEqual(self.info()["completed_at"], self.clock.isoformat())

        self.advance(1000)
        self.assertEqual(self.tracker.on_pxe(MAC), "guard-exists")
        self.assertEqual(len(self.events), 1, self.events)

    def test_repeat_pxe_without_prior_guard_emits_guard_and_complete(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.events.clear()

        self.advance(61)
        self.assertEqual(self.tracker.on_pxe(MAC), "guard")
        self.assertEqual(self.events, [
            ("guard-installed", self.base(reason="repeat-pxe")),
            ("install-complete", self.base(duration_seconds=61.0)),
        ])
        self.assertEqual(self.info()["completed_at"], self.clock.isoformat())

    def test_emit_failure_does_not_block_state_changes(self):
        def boom(_type, _data):
            raise OSError("journal unwritable")

        self.tracker.emit = boom
        self.seed([{"name": "t-1", "assigned": False}])

        with self.subTest(point="assign"):
            self.assertEqual(self.tracker.on_pxe(MAC), "assigned")
            self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-1")
            self.assertTrue(any("journal unwritable" in line for line in self.logs), self.logs)

        with self.subTest(point="hostname fetch"):
            self.assertTrue(self.tracker.on_hostname_fetch(MAC))
            self.assertTrue(self.guard().exists())

        with self.subTest(point="install complete"):
            self.advance(100)
            self.assertEqual(self.tracker.on_pxe(MAC), "guard-exists")
            self.assertEqual(self.info()["completed_at"], self.clock.isoformat())

        self.tracker.emit = lambda t, d: self.events.append((t, d))
        self.advance(200)
        self.tracker.on_pxe(MAC)
        self.assertEqual(self.events, [], "completed_at is stamped before emitting, so no re-emit on retry")

    def test_orphaned_assignment_is_reused_not_duplicated(self):
        self.seed([{"name": "t-1", "assigned": False}, {"name": "t-2", "assigned": False}])
        queue_store.assign_next(self.queue_dir, MAC)  # crash before the files were written

        self.assertEqual(self.tracker.on_pxe(MAC), "assigned")

        self.assertEqual((self.queue_dir / MAC / "hostname").read_text(), "t-1")
        entries = {e["name"]: e for e in queue_store.read(self.queue_dir)}
        self.assertEqual((entries["t-1"]["assigned"], entries["t-1"]["mac"]), (True, MAC))
        self.assertFalse(entries["t-2"]["assigned"])
        self.assertEqual(self.types(), ["machine-assigned"])

    def test_machine_info_written_atomically(self):
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        info_path = self.queue_dir / MAC / "machine-info.json"
        original = info_path.read_bytes()

        with mock.patch.object(watcher.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                watcher.write_info(self.queue_dir, MAC, {"name": "clobbered"})

        self.assertEqual(info_path.read_bytes(), original)
        self.assertEqual(sorted(p.name for p in (self.queue_dir / MAC).iterdir()), ["hostname", "machine-info.json"])


class FailureStateTest(RepoLayoutTest):
    """How installer reports and the timeout change a PXE machine's recorded state."""

    def setUp(self):
        super().setUp()
        self.clock = T0
        self.events = []

    def advance(self, seconds):
        self.clock = T0 + timedelta(seconds=seconds)

    def iso(self, seconds=0):
        return (T0 + timedelta(seconds=seconds)).isoformat(timespec="seconds")

    def machine(self, guard=False, **extra):
        """A PXE machine assigned at T0, optionally past its hostname fetch."""
        info = {"name": "t-1", "mac": MAC, "assigned_at": self.iso(), "attempt": 1}
        info.update(extra)
        (self.queue_dir / MAC).mkdir(parents=True, exist_ok=True)
        (self.queue_dir / MAC / "machine-info.json").write_text(json.dumps(info))
        self.seed([{"name": "t-1", "assigned": True, "mac": MAC}])
        if guard:
            watcher.write_guard(self.queue_dir, MAC)

    def forget(self):
        """Back to a blank repo layout between subTests."""
        shutil.rmtree(self.queue_dir)
        self.queue_dir.mkdir(parents=True)
        if self.guard_dir.exists():
            shutil.rmtree(self.guard_dir)
        self.events.clear()

    def info(self):
        return json.loads((self.queue_dir / MAC / "machine-info.json").read_text())

    def types(self):
        return [t for t, _ in self.events]

    def report_failure(self, source="installer", stage="tooling", reason="curl failed", **kwargs):
        return watcher.apply_failure(
            self.queue_dir, name="t-1", mac=MAC, stage=stage, reason=reason, source=source,
            now=self.clock, emit=lambda t, d: self.events.append((t, d)), log=lambda *_: None, **kwargs)

    def progress(self, stage):
        return watcher.apply_progress(
            self.queue_dir, name="t-1", mac=MAC, stage=stage, now=self.clock,
            emit=lambda t, d: self.events.append((t, d)), log=lambda *_: None)

    def test_repeated_or_late_failure_reports_do_no_harm(self):
        with self.subTest("a duplicate report emits one event and leaves the machine failed"):
            self.forget()
            self.machine(guard=True)
            self.report_failure(reason="first")
            result = self.report_failure(reason="second")
            self.assertIn("failed_at", self.info())
            self.assertFalse(self.guard().exists())
            self.assertEqual(self.types(), ["install-failed"])
            self.assertEqual(result, "duplicate")

        with self.subTest("a report after completion leaves the finished install alone"):
            self.forget()
            self.machine(guard=True, completed_at=self.iso(300))
            before = self.info()
            result = self.report_failure()
            self.assertEqual(self.info(), before)
            self.assertTrue(self.guard().exists())
            self.assertEqual(self.events, [])
            self.assertEqual(result, "ignored")

        with self.subTest("an unknown machine writes nothing"):
            self.forget()
            result = self.report_failure()
            self.assertFalse((self.queue_dir / MAC).exists())
            self.assertEqual(self.events, [])
            self.assertEqual(result, "unknown")

    def test_the_real_error_replaces_a_timeout_failure(self):
        self.machine(guard=True)
        self.report_failure(source="timeout", stage="unknown", reason="no installer activity for 45 minutes")
        self.events.clear()
        self.advance(60)

        result = self.report_failure(source="installer", stage="tooling", reason="curl failed")

        info = self.info()
        self.assertEqual((info["failure_source"], info["failure_reason"], info["stage"]), ("installer", "curl failed", "tooling"))
        self.assertIn("failed_at", info)
        self.assertEqual(self.types(), ["install-failed"])
        data = self.events[0][1]
        self.assertEqual((data["source"], data["reason"], data["stage"]), ("installer", "curl failed", "tooling"))
        self.assertEqual(result, "recorded")

        # From here on the failure is the installer's, so late progress is ignored.
        before = self.info()
        self.events.clear()
        self.assertEqual(self.progress("done"), "ignored")
        self.assertEqual(self.info(), before)
        self.assertEqual(self.events, [])

    def test_late_progress_after_a_failure(self):
        with self.subTest("an installer failure ignores late progress completely"):
            self.forget()
            self.machine(guard=True)
            self.report_failure(source="installer", stage="tooling")
            before = self.info()
            self.events.clear()
            self.advance(60)
            result = self.progress("tailscale")
            self.assertEqual(self.info(), before)
            self.assertFalse(self.guard().exists())
            self.assertEqual(self.events, [])
            self.assertEqual(result, "ignored")

        with self.subTest("a timeout failure is cleared and the guard comes back once past the hostname fetch"):
            self.forget()
            self.machine(guard=True)
            self.report_failure(source="timeout", stage="unknown", reason="no installer activity for 45 minutes")
            self.events.clear()
            self.advance(60)
            result = self.progress("tooling")
            info = self.info()
            for key in ("failed_at", "failure_reason", "failure_source"):
                self.assertNotIn(key, info)
            self.assertEqual((info["stage"], info["progress_at"]), ("tooling", self.iso(60)))
            self.assertTrue(self.guard().exists())
            self.assertEqual(self.types(), ["install-progress"])
            self.assertEqual(result, "recorded")

        with self.subTest("a timeout failure cleared before the hostname fetch gets no guard early"):
            self.forget()
            self.machine(guard=False)
            self.report_failure(source="timeout", stage="unknown", reason="no installer activity for 45 minutes")
            self.advance(60)
            result = self.progress("late-commands")
            info = self.info()
            self.assertNotIn("failed_at", info)
            self.assertEqual(info["stage"], "late-commands")
            self.assertFalse(self.guard().exists())
            self.assertEqual(result, "recorded")

    def test_repeated_progress_reports_keep_an_install_alive(self):
        with self.subTest("a new stage is recorded and announced"):
            self.forget()
            self.machine()
            self.advance(30)
            result = self.progress("identity")
            info = self.info()
            self.assertEqual((info["stage"], info["progress_at"]), ("identity", self.iso(30)))
            self.assertEqual(self.types(), ["install-progress"])
            self.assertEqual(self.events[0][1]["stage"], "identity")
            self.assertEqual(result, "recorded")

        with self.subTest("a repeated stage is silent but still moves the deadline"):
            self.forget()
            self.machine(stage="tooling", progress_at=self.iso(30))
            self.advance(900)
            result = self.progress("tooling")
            self.assertEqual(self.info()["progress_at"], self.iso(900))
            self.assertEqual(self.events, [])
            self.assertEqual(result, "duplicate")

        with self.subTest("progress after completion changes nothing"):
            self.forget()
            self.machine(guard=True, completed_at=self.iso(300), stage="done")
            before = self.info()
            self.advance(400)
            result = self.progress("tooling")
            self.assertEqual(self.info(), before)
            self.assertEqual(self.events, [])
            self.assertEqual(result, "ignored")

    def test_the_timeout_loses_to_a_report_that_just_arrived(self):
        cutoff = T0 + timedelta(seconds=50)

        with self.subTest("activity after the cutoff means the install is alive"):
            self.forget()
            self.machine(guard=True, progress_at=self.iso(100))
            before = self.info()
            result = self.report_failure(source="timeout", stage="unknown", reason="no installer activity", stale_before=cutoff)
            self.assertEqual(self.info(), before)
            self.assertTrue(self.guard().exists())
            self.assertEqual(self.events, [])
            self.assertEqual(result, "ignored")

        with self.subTest("activity before the cutoff is a silent install"):
            self.forget()
            self.machine(guard=True, progress_at=self.iso(10))
            result = self.report_failure(source="timeout", stage="unknown", reason="no installer activity", stale_before=cutoff)
            self.assertIn("failed_at", self.info())
            self.assertFalse(self.guard().exists())
            self.assertEqual(self.types(), ["install-failed"])
            self.assertEqual(result, "recorded")


class RetryTest(RepoLayoutTest):
    """A machine whose install failed, or that `just unguard` re-armed, reinstalls on its next boot."""

    RETRY_KEYS = ("completed_at", "failed_at", "failure_reason", "failure_source", "stage", "progress_at", "armed")

    def setUp(self):
        super().setUp()
        self.clock = T0
        self.events = []
        self.tracker = watcher.PxeTracker(
            self.queue_dir, now=lambda: self.clock, log=lambda *_: None,
            emit=lambda t, d: self.events.append((t, d)))

    def advance(self, seconds):
        self.clock = T0 + timedelta(seconds=seconds)

    def iso(self, seconds=0):
        return (T0 + timedelta(seconds=seconds)).isoformat(timespec="seconds")

    def info(self):
        return json.loads((self.queue_dir / MAC / "machine-info.json").read_text())

    def types(self):
        return [t for t, _ in self.events]

    def forget(self):
        shutil.rmtree(self.queue_dir)
        self.queue_dir.mkdir(parents=True)
        if self.guard_dir.exists():
            shutil.rmtree(self.guard_dir)
        self.events.clear()
        self.advance(0)

    def installing(self):
        """Assigned and past its hostname fetch, so the guard is in place."""
        self.seed([{"name": "t-1", "assigned": False}])
        self.tracker.on_pxe(MAC)
        self.tracker.on_hostname_fetch(MAC)

    def report_failure(self, source="installer"):
        return watcher.apply_failure(
            self.queue_dir, name="t-1", mac=MAC, stage="tooling", reason="curl failed", source=source,
            now=self.clock, emit=None, log=lambda *_: None)

    def break_install(self, how):
        """Put a machine in the state a retry starts from, then forget the events so far."""
        self.installing()
        self.advance(300)
        if how == "failed":
            self.report_failure()
        else:
            self.tracker.on_pxe(MAC)  # the post-install reboot completes it
            watcher.arm_retry(self.queue_dir, MAC)
        self.events.clear()

    def test_a_failed_machine_reinstalls_on_its_next_boot(self):
        for how in ("failed", "armed"):
            with self.subTest(trigger=how):
                self.forget()
                self.break_install(how)
                self.advance(900)

                result = self.tracker.on_pxe(MAC)

                info = self.info()
                self.assertEqual(info["assigned_at"], self.iso(900))
                self.assertEqual(info["attempt"], 2)
                for key in self.RETRY_KEYS:
                    self.assertNotIn(key, info)
                self.assertFalse(self.guard().exists())
                self.assertEqual(self.types(), ["machine-assigned"])
                self.assertEqual(result, "rearmed")

    def test_one_reboot_starts_only_one_new_attempt(self):
        self.break_install("failed")
        results = []
        for seconds in (600, 603, 612, 659):
            self.advance(seconds)
            results.append(self.tracker.on_pxe(MAC))

        info = self.info()
        self.assertEqual(info["attempt"], 2)
        self.assertNotIn("completed_at", info)
        self.assertFalse(self.guard().exists())
        self.assertEqual(self.types(), ["machine-assigned"])
        self.assertEqual(results, ["rearmed", "retry", "retry", "retry"])

    def test_a_retried_install_reports_the_right_duration(self):
        self.break_install("failed")
        self.advance(600)
        self.tracker.on_pxe(MAC)  # the reboot that starts the new attempt
        self.events.clear()
        self.advance(661)

        result = self.tracker.on_pxe(MAC)

        self.assertEqual(self.info()["completed_at"], self.iso(661))
        self.assertTrue(self.guard().exists())
        self.assertEqual(self.types(), ["guard-installed", "install-complete"])
        self.assertEqual(self.events[1][1]["duration_seconds"], 61.0)
        self.assertEqual(result, "guard")

    def test_a_late_hostname_fetch_after_a_failure(self):
        with self.subTest("after an installer failure the guard stays off and the failure stands"):
            self.forget()
            self.installing()
            self.advance(300)
            self.report_failure(source="installer")
            self.events.clear()
            result = self.tracker.on_hostname_fetch(MAC)
            self.assertFalse(self.guard().exists())
            self.assertIn("failed_at", self.info())
            self.assertEqual(self.events, [])
            self.assertFalse(result)

        with self.subTest("after a timeout failure the guard comes back and the failure clears"):
            self.forget()
            self.installing()
            self.advance(300)
            self.report_failure(source="timeout")
            self.events.clear()
            result = self.tracker.on_hostname_fetch(MAC)
            info = self.info()
            for key in ("failed_at", "failure_reason", "failure_source"):
                self.assertNotIn(key, info)
            self.assertTrue(self.guard().exists())
            self.assertEqual(self.types(), ["install-started", "guard-installed"])
            self.assertTrue(result)


class InfoLockTest(RepoLayoutTest):
    """Both the root watcher and the operator-run API write machine-info.json."""

    def setUp(self):
        super().setUp()
        (self.queue_dir / MAC).mkdir()
        (self.queue_dir / MAC / "machine-info.json").write_text(json.dumps({"name": "t-1", "mac": MAC}))

    def lock(self, timeout):
        return queue_store.locked_file(self.queue_dir / watcher.INFO_LOCK, self.queue_dir, timeout=timeout)

    def test_two_writers_cannot_update_one_machine_record_at_once(self):
        entered, release = threading.Event(), threading.Event()

        def slow_update(info):
            entered.set()
            release.wait(5)
            info["touched"] = True
            return True

        worker = threading.Thread(target=watcher.update_info, args=(self.queue_dir, MAC, slow_update))
        worker.start()
        try:
            self.assertTrue(entered.wait(5), "update never started")
            with self.assertRaises(TimeoutError):
                with self.lock(0.1):
                    pass
        finally:
            release.set()
            worker.join(5)

        with self.lock(1.0):
            pass
        self.assertTrue(json.loads((self.queue_dir / MAC / "machine-info.json").read_text())["touched"])

    def test_the_lock_is_released_when_the_update_raises(self):
        def boom(info):
            raise RuntimeError("inside")

        with self.assertRaises(RuntimeError):
            watcher.update_info(self.queue_dir, MAC, boom)

        with self.lock(0.1):
            pass


if __name__ == "__main__":
    unittest.main()
