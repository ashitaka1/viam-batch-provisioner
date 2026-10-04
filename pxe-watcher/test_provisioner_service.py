"""Tests for the provisioning service: request validation, credential staging
under the queue lock, disk-derived queue status, and removal.

Status is derived from disk alone so that operator actions done with rm
(reset, clean, unguard) are reflected without any process restart.
"""

import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import provisioner_service as svc  # noqa: E402
import queue_store  # noqa: E402

MAC = "aa:bb:cc:dd:ee:ff"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
CREDS = {"cloud": {"app_address": "https://app.viam.com:443", "id": "part-1", "secret": "s3cr3t"}}


class StubHub:
    def __init__(self, last_id=0):
        self.last_id = last_id


class ServiceLayoutTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.queue_dir = self.root / "http-server" / "machines"
        self.queue_dir.mkdir(parents=True)
        self.guard_dir = self.root / "netboot" / "grub" / "provisioned"
        self.hub = StubHub()

    def tearDown(self):
        self._tmp.cleanup()

    def service(self):
        return svc.ProvisionService(self.queue_dir, hub=self.hub, now=lambda: T0)

    def seed(self, entries):
        (self.queue_dir / "queue.json").write_text(json.dumps(entries, indent=2))

    def queue(self):
        return json.loads((self.queue_dir / "queue.json").read_text())

    def slot_file(self, name):
        return self.queue_dir / f"slot-{name}" / "viam.json"

    def write_slot(self, name, text):
        self.slot_file(name).parent.mkdir(parents=True, exist_ok=True)
        self.slot_file(name).write_text(text)

    def write_info(self, mac, **extra):
        info = {"name": extra.pop("name", "m"), "mac": mac, "assigned_at": T0.isoformat()}
        info.update(extra)
        (self.queue_dir / mac).mkdir(parents=True, exist_ok=True)
        (self.queue_dir / mac / "machine-info.json").write_text(json.dumps(info))

    def write_guard(self, mac):
        self.guard_dir.mkdir(parents=True, exist_ok=True)
        (self.guard_dir / f"{mac}.cfg").write_text("exit\n")


class ValidateProvisionTest(ServiceLayoutTest):
    def test_rejects_invalid_items_atomically(self):
        good = {"name": "ok", "credentials": CREDS}
        bad_cases = [
            ([{"name": "Bad"}], 0, "name"),
            ([{"name": "-a"}], 0, "name"),
            ([{"name": "a-"}], 0, "name"),
            ([{"name": ".."}], 0, "name"),
            ([{"name": "a/b"}], 0, "name"),
            ([{"name": ""}], 0, "name"),
            ([{"name": "a" * 64}], 0, "name"),
            ([{"name": "a\n"}], 0, "name"),
            ([good, {"name": "ok2", "credentials": {"cloud": {"id": "x"}}}], 1, "credentials"),
            ([{"name": "ok", "credentials": "string"}], 0, "credentials"),
            ([{"name": "ok"}, "not-an-object"], 1, None),
            ({"name": "ok"}, None, None),
            ([], None, None),
            ([{"name": "ok"}] * 501, None, None),
            ([good, {"name": "Bad"}], 1, "name"),
        ]
        for body, index, field in bad_cases:
            with self.subTest(body=str(body)[:60]):
                with self.assertRaises(svc.ValidationError) as cm:
                    self.service().provision(body)
                detail = cm.exception.details[0]
                self.assertEqual(detail.get("index"), index, detail)
                self.assertEqual(detail.get("field"), field, detail)
                self.assertFalse((self.queue_dir / "queue.json").exists(), "a rejected batch must write nothing")
                self.assertEqual(sorted(p.name for p in self.queue_dir.iterdir()), [], "no slot dir may be left behind")

        accepted = ["a", "a-1", "a" * 63]
        results = self.service().provision([{"name": n} for n in accepted])
        self.assertEqual([r["result"] for r in results], ["added"] * 3)


class ProvisionTest(ServiceLayoutTest):
    def test_stages_credentials_and_links_queue_entry(self):
        results = self.service().provision([{"name": "full", "credentials": CREDS}, {"name": "bare"}])

        self.assertEqual(results, [{"name": "full", "result": "added"}, {"name": "bare", "result": "added"}])
        self.assertEqual(json.loads(self.slot_file("full").read_text()), CREDS)
        self.assertFalse(self.slot_file("bare").parent.exists())
        by_name = {e["name"]: e for e in self.queue()}
        self.assertEqual(by_name["full"]["slot_id"], "slot-full")
        self.assertNotIn("slot_id", by_name["bare"])
        entries = {e["name"]: e for e in self.service().list_queue()["entries"]}
        self.assertTrue(entries["full"]["has_credentials"])
        self.assertFalse(entries["bare"]["has_credentials"])

    def test_partial_stage_failure_leaves_nothing(self):
        self.seed([{"name": "x", "assigned": False}])
        before = (self.queue_dir / "queue.json").read_bytes()
        real_writer = svc.write_slot_file

        def failing_writer(slot_dir, credentials):
            if slot_dir.name == "slot-b":
                raise OSError("disk full")
            real_writer(slot_dir, credentials)

        with mock.patch.object(svc, "write_slot_file", failing_writer):
            with self.assertRaises(svc.StageFailed):
                self.service().provision([{"name": "a", "credentials": CREDS}, {"name": "b", "credentials": CREDS}])

        self.assertEqual((self.queue_dir / "queue.json").read_bytes(), before)
        self.assertFalse(self.slot_file("a").parent.exists(), "slot staged earlier in the batch must be removed")
        self.assertFalse(self.slot_file("b").parent.exists())

    def test_skips_queued_name_without_touching_credentials(self):
        self.seed([{"name": "a", "slot_id": "slot-a", "assigned": True, "mac": MAC}])
        self.write_slot("a", '{"orig": 1}')
        other = {"cloud": {"id": "new", "secret": "new"}}

        results = self.service().provision([{"name": "a", "credentials": other}, {"name": "a"}])

        self.assertEqual(results, [
            {"name": "a", "result": "skipped", "reason": "already-queued"},
            {"name": "a", "result": "skipped", "reason": "duplicate-in-request"},
        ])
        self.assertEqual(self.slot_file("a").read_text(), '{"orig": 1}')


class DeriveEntryTest(ServiceLayoutTest):
    def derive(self, raw):
        return svc.derive_entry(self.queue_dir, raw)

    def test_status_table(self):
        assigned_raw = {"name": "m", "assigned": True, "mac": MAC}
        done = T0 + timedelta(minutes=6)

        with self.subTest(state="queued"):
            entry = self.derive({"name": "q", "assigned": False})
            self.assertEqual(entry["status"], "queued")
            self.assertNotIn("mac", entry)
            self.assertNotIn("assigned_at", entry)

        with self.subTest(state="flashed"):
            entry = self.derive({"name": "f", "assigned": True, "flashed_via": "usb"})
            self.assertEqual((entry["status"], entry["flashed_via"]), ("flashed", "usb"))

        with self.subTest(state="assigned, info missing"):
            entry = self.derive(assigned_raw)
            self.assertEqual((entry["status"], entry["mac"]), ("assigned", MAC))
            self.assertNotIn("assigned_at", entry)

        self.write_info(MAC)
        with self.subTest(state="assigned, no guard"):
            entry = self.derive(assigned_raw)
            self.assertEqual((entry["status"], entry["assigned_at"]), ("assigned", T0.isoformat()))

        self.write_guard(MAC)
        with self.subTest(state="installing"):
            self.assertEqual(self.derive(assigned_raw)["status"], "installing")

        self.write_info(MAC, completed_at=done.isoformat())
        with self.subTest(state="installed"):
            entry = self.derive(assigned_raw)
            self.assertEqual((entry["status"], entry["completed_at"]), ("installed", done.isoformat()))

        with self.subTest(state="guard removed by hand"):
            (self.guard_dir / f"{MAC}.cfg").unlink()
            self.assertEqual(self.derive(assigned_raw)["status"], "assigned")

        with self.subTest(state="mac dir removed by hand"):
            (self.queue_dir / MAC / "machine-info.json").unlink()
            entry = self.derive(assigned_raw)
            self.assertEqual(entry["status"], "assigned")
            self.assertNotIn("assigned_at", entry)

        with self.subTest(state="after reset"):
            self.assertEqual(self.derive({"name": "m", "assigned": False, "mac": None})["status"], "queued")

        with self.subTest(state="has_credentials"):
            self.assertFalse(self.derive({"name": "m", "assigned": False})["has_credentials"])
            self.write_slot("m", "{}")
            self.assertTrue(self.derive({"name": "m", "assigned": False, "slot_id": "slot-m"})["has_credentials"])
            (self.queue_dir / MAC / "viam.json").write_text("{}")
            self.assertTrue(self.derive({"name": "n", "assigned": True, "mac": MAC})["has_credentials"])


class RemoveTest(ServiceLayoutTest):
    def test_cleans_slot_only_when_removed(self):
        self.seed([
            {"name": "a", "slot_id": "slot-a", "assigned": False},
            {"name": "b", "slot_id": "slot-b", "assigned": True, "mac": MAC},
        ])
        self.write_slot("a", "{}")
        self.write_slot("b", "{}")

        self.service().remove("a")
        self.assertEqual([e["name"] for e in self.queue()], ["b"])
        self.assertFalse(self.slot_file("a").parent.exists())

        with self.assertRaises(svc.Conflict):
            self.service().remove("b")
        self.assertEqual([e["name"] for e in self.queue()], ["b"])
        self.assertTrue(self.slot_file("b").exists())

        with self.assertRaises(svc.NotFound):
            self.service().remove("z")


class QueueReadTest(ServiceLayoutTest):
    def test_read_errors_map_to_service_errors(self):
        self.assertEqual(self.service().list_queue()["entries"], [])
        (self.queue_dir / "queue.json").write_text("{not json")
        with self.assertRaises(svc.QueueUnreadable):
            self.service().list_queue()

    def test_snapshot_last_event_id_is_read_before_queue(self):
        self.seed([{"name": "a", "assigned": False}])
        self.assertEqual(self.service().list_queue()["last_event_id"], 0)
        self.hub.last_id = 5
        self.assertEqual(self.service().list_queue()["last_event_id"], 5)

        real_read = queue_store.read

        def read_then_emit(queue_dir):
            entries = real_read(queue_dir)
            self.hub.last_id += 1
            return entries

        with mock.patch.object(queue_store, "read", read_then_emit):
            snapshot = self.service().list_queue()
        self.assertEqual(snapshot["last_event_id"], 5, "last_event_id must be captured before the queue is read")
        self.assertEqual(self.hub.last_id, 6)


if __name__ == "__main__":
    unittest.main()
