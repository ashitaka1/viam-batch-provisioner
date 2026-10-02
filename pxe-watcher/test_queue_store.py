#!/usr/bin/env python3
"""Tests for queue_store, the single writer of queue.json.

The watcher daemon and the operator's provision/flash scripts write the
same file from different processes. These tests pin the merge, assignment,
locking and atomic-write contracts that keep them from clobbering each other.
"""

import json
import subprocess
import sys
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import queue_store  # noqa: E402


def _entry(name, assigned=False, mac=None, slot_id=None):
    e = {"name": name, "assigned": assigned}
    if slot_id is not None:
        e["slot_id"] = slot_id
    if mac is not None:
        e["mac"] = mac
    return e


class QueueDirTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.queue_dir = Path(self._tmp.name)
        self.queue_file = self.queue_dir / "queue.json"

    def tearDown(self):
        self._tmp.cleanup()

    def seed(self, entries):
        self.queue_file.write_text(json.dumps(entries, indent=2))

    def on_disk(self):
        return json.loads(self.queue_file.read_text())

    def snapshot(self):
        st = self.queue_file.stat()
        return self.queue_file.read_bytes(), st.st_ino


class AssignNextTest(QueueDirTest):
    def test_assigns_first_unassigned_and_preserves_others(self):
        self.seed([
            _entry("p-1", assigned=True, mac="aa:aa:aa:aa:aa:01", slot_id="slot-p-1"),
            _entry("p-2", slot_id="slot-p-2"),
            _entry("p-3"),
        ])
        got = queue_store.assign_next(self.queue_dir, "aa:aa:aa:aa:aa:02")
        self.assertEqual(got["name"], "p-2")
        self.assertEqual(got["slot_id"], "slot-p-2")

        disk = self.on_disk()
        self.assertEqual([e["name"] for e in disk], ["p-1", "p-2", "p-3"])
        self.assertEqual(disk[0], _entry("p-1", True, "aa:aa:aa:aa:aa:01", "slot-p-1"))
        self.assertTrue(disk[1]["assigned"])
        self.assertEqual(disk[1]["mac"], "aa:aa:aa:aa:aa:02")
        self.assertFalse(disk[2]["assigned"])

    def test_picks_up_entry_added_between_calls(self):
        self.seed([_entry("p-1")])
        queue_store.assign_next(self.queue_dir, "aa:aa:aa:aa:aa:01")
        # Another process appends while we hold nothing in memory.
        disk = self.on_disk()
        disk.append(_entry("p-2"))
        self.seed(disk)
        got = queue_store.assign_next(self.queue_dir, "aa:aa:aa:aa:aa:02")
        self.assertEqual(got["name"], "p-2")

    def test_missing_file_returns_none_and_creates_nothing(self):
        self.assertIsNone(queue_store.assign_next(self.queue_dir, "aa:aa:aa:aa:aa:01"))
        self.assertFalse(self.queue_file.exists())
        self.assertEqual(sorted(p.name for p in self.queue_dir.iterdir() if p.name.startswith(".queue")), [])

    def test_exhausted_queue_returns_none_without_rewrite(self):
        for label, entries in (
            ("empty", []),
            ("all-assigned", [_entry("p-1", True, "aa:aa:aa:aa:aa:01")]),
        ):
            with self.subTest(label):
                self.seed(entries)
                before = self.snapshot()
                self.assertIsNone(queue_store.assign_next(self.queue_dir, "bb:bb:bb:bb:bb:01"))
                self.assertEqual(self.snapshot(), before)


class CorruptQueueTest(QueueDirTest):
    def test_invalid_json_raises_and_is_not_rewritten(self):
        self.queue_file.write_text("{not json")
        before = self.snapshot()
        with self.assertRaises(json.JSONDecodeError):
            queue_store.read(self.queue_dir)
        with self.assertRaises(json.JSONDecodeError):
            queue_store.assign_next(self.queue_dir, "aa:aa:aa:aa:aa:01")
        self.assertEqual(self.snapshot(), before)


class AppendTest(QueueDirTest):
    def test_merges_new_names_and_skips_existing(self):
        self.seed([
            _entry("p-1", True, "aa:aa:aa:aa:aa:01"),
            _entry("p-2"),
        ])
        added, skipped = queue_store.append(self.queue_dir, [
            _entry("p-2"),            # already present, unassigned
            _entry("p-1"),            # already present, assigned
            _entry("p-3"),
            _entry("p-3"),            # duplicate within the call
            _entry("p-4", slot_id="slot-p-4"),
        ])
        self.assertEqual([e["name"] for e in added], ["p-3", "p-4"])
        self.assertEqual(skipped, ["p-2", "p-1", "p-3"])

        disk = self.on_disk()
        self.assertEqual([e["name"] for e in disk], ["p-1", "p-2", "p-3", "p-4"])
        self.assertEqual(disk[0], _entry("p-1", True, "aa:aa:aa:aa:aa:01"))
        self.assertEqual(disk[3]["slot_id"], "slot-p-4")

    def test_append_to_missing_file_creates_it(self):
        added, skipped = queue_store.append(self.queue_dir, [_entry("p-1")])
        self.assertEqual([e["name"] for e in added], ["p-1"])
        self.assertEqual(skipped, [])
        self.assertEqual(self.on_disk(), [_entry("p-1")])

    def test_empty_append_does_not_rewrite(self):
        self.seed([_entry("p-1")])
        before = self.snapshot()
        self.assertEqual(queue_store.append(self.queue_dir, []), ([], []))
        self.assertEqual(self.snapshot(), before)


class MarkAssignedTest(QueueDirTest):
    def test_sets_assigned_and_extra_keys(self):
        self.seed([_entry("p-1"), _entry("p-2")])
        self.assertTrue(queue_store.mark_assigned(self.queue_dir, "p-2", flashed_via="usb"))
        disk = self.on_disk()
        self.assertFalse(disk[0]["assigned"])
        self.assertTrue(disk[1]["assigned"])
        self.assertEqual(disk[1]["flashed_via"], "usb")

    def test_unknown_name_returns_false_without_rewrite(self):
        self.seed([_entry("p-1")])
        before = self.snapshot()
        self.assertFalse(queue_store.mark_assigned(self.queue_dir, "nope"))
        self.assertEqual(self.snapshot(), before)


class SummaryTest(QueueDirTest):
    def test_counts_unassigned_and_total(self):
        self.assertEqual(queue_store.summary(self.queue_dir), (0, 0))
        self.seed([_entry("p-1", True, "aa:aa:aa:aa:aa:01"), _entry("p-2"), _entry("p-3")])
        self.assertEqual(queue_store.summary(self.queue_dir), (2, 3))


class NextIndexTest(QueueDirTest):
    def test_missing_or_empty_queue_starts_at_one(self):
        self.assertEqual(queue_store.next_index(self.queue_dir, "p"), 1)
        self.seed([])
        self.assertEqual(queue_store.next_index(self.queue_dir, "p"), 1)

    def test_continues_after_highest_with_gaps(self):
        self.seed([_entry("p-1"), _entry("p-2"), _entry("p-5")])
        self.assertEqual(queue_store.next_index(self.queue_dir, "p"), 6)

    def test_compares_numerically(self):
        self.seed([_entry("p-9"), _entry("p-10")])
        self.assertEqual(queue_store.next_index(self.queue_dir, "p"), 11)

    def test_ignores_other_prefixes_and_malformed_suffixes(self):
        self.seed([
            _entry("other-9"), _entry("p-foo"), _entry("p-1a"), _entry("p-1-2"),
            _entry("p-2"),
        ])
        self.assertEqual(queue_store.next_index(self.queue_dir, "p"), 3)

    def test_prefix_is_matched_literally(self):
        self.seed([_entry("aXb-3")])
        self.assertEqual(queue_store.next_index(self.queue_dir, "a.b"), 1)


class WriteTest(QueueDirTest):
    def temp_files(self):
        return [p.name for p in self.queue_dir.iterdir() if p.name.startswith(".queue.json.")]

    def test_success_leaves_only_queue_file(self):
        queue_store.write(self.queue_dir, [_entry("p-1")])
        self.assertEqual(self.on_disk(), [_entry("p-1")])
        self.assertEqual(self.temp_files(), [])

    def test_failed_replace_leaves_original_and_no_temp(self):
        self.seed([_entry("p-1")])
        before = self.queue_file.read_bytes()
        with mock.patch.object(queue_store.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                queue_store.write(self.queue_dir, [_entry("p-2")])
        self.assertEqual(self.queue_file.read_bytes(), before)
        self.assertEqual(self.temp_files(), [])


class LockTest(QueueDirTest):
    def test_excludes_other_process_until_released(self):
        child_src = (
            "import sys\n"
            f"sys.path.insert(0, {str(HERE)!r})\n"
            "from pathlib import Path\n"
            "import queue_store\n"
            f"with queue_store.locked(Path({str(self.queue_dir)!r})):\n"
            "    print('READY', flush=True)\n"
            "    sys.stdin.read()\n"
        )
        proc = subprocess.Popen(
            [sys.executable, "-c", child_src],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(proc.stdout.readline().strip(), "READY")
            with self.assertRaises(TimeoutError):
                with queue_store.locked(self.queue_dir, timeout=0.1):
                    pass
            proc.stdin.close()
            proc.wait(timeout=5)
            with queue_store.locked(self.queue_dir, timeout=2.0):
                pass
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_released_when_body_raises(self):
        with self.assertRaises(RuntimeError):
            with queue_store.locked(self.queue_dir):
                raise RuntimeError("inside")
        with queue_store.locked(self.queue_dir, timeout=0.1):
            pass

    def test_concurrent_assign_next_hands_out_distinct_entries(self):
        n = 8
        self.seed([_entry(f"p-{i}") for i in range(1, n + 1)])
        results = [None] * n
        start = threading.Barrier(n)

        def worker(i):
            start.wait()
            results[i] = queue_store.assign_next(self.queue_dir, f"aa:aa:aa:aa:aa:{i:02x}")

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        names = [r["name"] if r else None for r in results]
        self.assertNotIn(None, names)
        self.assertEqual(len(set(names)), n)
        disk = self.on_disk()
        self.assertEqual(sum(1 for e in disk if e["assigned"]), n)
        self.assertEqual(len(disk), n)


class CliTest(QueueDirTest):
    def run_cli(self, *args, stdin=None):
        return subprocess.run(
            [sys.executable, str(HERE / "queue_store.py"), *args, "--queue-dir", str(self.queue_dir)],
            input=stdin, capture_output=True, text=True,
        )

    def test_has_name_exit_codes(self):
        self.seed([_entry("p-1")])
        self.assertEqual(self.run_cli("has-name", "--name", "p-1").returncode, 0)
        self.assertEqual(self.run_cli("has-name", "--name", "p-2").returncode, 1)

    def test_next_index_prints_integer(self):
        self.seed([_entry("p-4")])
        out = self.run_cli("next-index", "--prefix", "p")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "5")

    def test_append_reports_each_entry(self):
        self.seed([_entry("p-1")])
        out = self.run_cli("append", stdin=json.dumps([_entry("p-1"), _entry("p-2"), _entry("p-2")]))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), ["skipped p-1", "added p-2", "skipped p-2"])
        self.assertEqual([e["name"] for e in self.on_disk()], ["p-1", "p-2"])


if __name__ == "__main__":
    unittest.main()
