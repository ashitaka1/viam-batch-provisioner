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

import event_journal  # noqa: E402
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


class ValidateReportTest(unittest.TestCase):
    def report(self, **fields):
        body = {"kind": "progress", "stage": "identity", "mac": MAC}
        body.update(fields)
        return body

    def test_malformed_reports_are_rejected(self):
        bad = {
            "not an object": [],
            "neither name nor mac": {"kind": "progress", "stage": "identity"},
            "both name and mac": self.report(name="m"),
            "uppercase mac": self.report(mac=MAC.upper()),
            "unknown kind": self.report(kind="nope"),
            "missing stage": {"kind": "progress", "mac": MAC},
            "unknown stage": self.report(stage="bogus"),
            "a stage only the server may set": self.report(kind="failed", stage="unknown"),
            "done with a failure": self.report(kind="failed", stage="done"),
            "installer with progress": self.report(stage="installer"),
            "non-string reason": self.report(kind="failed", stage="tooling", reason=5),
            "name with a slash": {"kind": "progress", "stage": "identity", "name": "a/b"},
        }
        for label, body in bad.items():
            with self.subTest(label):
                with self.assertRaises(svc.ValidationError):
                    svc.validate_report(body)

    def test_reasons_are_cleaned_and_bounded(self):
        limit = svc.MAX_REASON
        cases = {
            "control characters and newlines become single spaces": ("curl\x00 failed\n\non line 3\t!", "curl failed on line 3 !"),
            "exactly at the limit is kept": ("x" * limit, "x" * limit),
            "one over the limit is cut": ("x" * (limit + 1), "x" * limit),
        }
        for label, (raw, expected) in cases.items():
            with self.subTest(label):
                got = svc.validate_report(self.report(kind="failed", stage="tooling", reason=raw))["reason"]
                self.assertEqual(got, expected)
        for label, raw in {"whitespace only": " \n\t ", "absent": None}.items():
            with self.subTest(label):
                got = svc.validate_report(self.report(kind="failed", stage="tooling", reason=raw))["reason"]
                self.assertTrue(got.strip(), "an empty reason must be replaced with readable text")


class FailedStatusTest(ServiceLayoutTest):
    def test_a_failed_machine_is_not_shown_as_waiting_or_installing(self):
        raw = {"name": "m", "assigned": True, "mac": MAC}
        self.write_info(MAC, failed_at=T0.isoformat(), failure_reason="boom", failure_source="installer", stage="tooling")

        with self.subTest("no guard, which on its own reads as waiting"):
            entry = svc.derive_entry(self.queue_dir, raw, self.guard_dir)
            self.assertEqual((entry["failed_at"], entry["failure_reason"], entry["stage"]), (T0.isoformat(), "boom", "tooling"))
            self.assertEqual(entry["mac"], MAC)
            self.assertEqual(entry["status"], "failed")

        with self.subTest("guard present, which on its own reads as installing"):
            self.write_guard(MAC)
            self.assertEqual(svc.derive_entry(self.queue_dir, raw, self.guard_dir)["status"], "failed")

        with self.subTest("a USB machine"):
            usb = {"name": "u", "assigned": True, "flashed_via": "usb", "failed_at": T0.isoformat(),
                   "failure_reason": "boom", "stage": "installer"}
            entry = svc.derive_entry(self.queue_dir, usb, self.guard_dir)
            self.assertEqual((entry["failure_reason"], entry["stage"], entry["flashed_via"]), ("boom", "installer", "usb"))
            self.assertEqual(entry["status"], "failed")

        with self.subTest("counts include a failed bucket"):
            counted = svc.counts([{"status": "failed"}, {"status": "failed"}, {"status": "queued"}])
            self.assertEqual((counted["failed"], counted["queued"], counted["total"]), (2, 1, 3))


class ReportInstallTest(ServiceLayoutTest):
    def setUp(self):
        super().setUp()
        self.journal_path = self.root / "logs" / "events.jsonl"
        self.journal = event_journal.EventJournal(self.journal_path, now=lambda: T0)

    def service(self):
        return svc.ProvisionService(self.queue_dir, hub=self.hub, now=lambda: T0, guard_dir=self.guard_dir, emit=self.journal.emit)

    def events(self):
        return [r["data"] for r in event_journal.read_all(self.journal_path)] if self.journal_path.exists() else []

    def info(self):
        return json.loads((self.queue_dir / MAC / "machine-info.json").read_text())

    def failed(self, **who):
        body = {"kind": "failed", "stage": "tooling", "reason": "curl failed"}
        body.update(who)
        return body

    def test_reports_reach_the_right_machine(self):
        with self.subTest("a PXE machine by mac"):
            self.seed([{"name": "m", "assigned": True, "mac": MAC}])
            self.write_info(MAC, name="m", attempt=1)
            self.write_guard(MAC)
            result = self.service().report_install(self.failed(mac=MAC))
            self.assertEqual((self.info()["failure_reason"], self.info()["stage"]), ("curl failed", "tooling"))
            self.assertFalse((self.guard_dir / f"{MAC}.cfg").exists())
            self.assertEqual([(e["type"], e["name"], e["mac"]) for e in self.events()], [("install-failed", "m", MAC)])
            self.assertEqual(result, {"result": "recorded"})

        with self.subTest("a name bound to a MAC takes the PXE path"):
            self.journal_path.unlink(missing_ok=True)
            self.write_info(MAC, name="m", attempt=1)
            self.write_guard(MAC)
            result = self.service().report_install(self.failed(name="m"))
            self.assertIn("failed_at", self.info())
            self.assertEqual([e["mac"] for e in self.events()], [MAC])
            self.assertEqual(result, {"result": "recorded"})

        with self.subTest("a USB machine is recorded on its queue entry and its event has no mac"):
            self.journal_path.unlink(missing_ok=True)
            self.seed([{"name": "u", "assigned": True, "flashed_via": "usb"}])
            result = self.service().report_install(self.failed(name="u", stage="installer"))
            entry = self.queue()[0]
            self.assertEqual((entry["failure_reason"], entry["stage"]), ("curl failed", "installer"))
            self.assertIn("failed_at", entry)
            events = self.events()
            self.assertEqual([e["name"] for e in events], ["u"])
            self.assertNotIn("mac", events[0])
            self.assertEqual(result, {"result": "recorded"})

        for label, body, entries in [
            ("an unassigned entry", self.failed(name="q"), [{"name": "q", "assigned": False}]),
            ("an unknown name", self.failed(name="nope"), []),
            ("an unknown mac", self.failed(mac="11:22:33:44:55:66"), []),
        ]:
            with self.subTest(label):
                self.journal_path.unlink(missing_ok=True)
                self.seed(entries)
                with self.assertRaises(svc.NotFound):
                    self.service().report_install(body)
                self.assertEqual(self.events(), [])

    def test_a_usb_machine_leaves_failed_when_its_stick_boots_again(self):
        # A USB install has no re-arm and no timeout, so a progress report
        # after its failure can only mean the stick was booted again.
        self.seed([{"name": "u", "assigned": True, "flashed_via": "usb"}])
        service = self.service()
        service.report_install(self.failed(name="u", stage="installer"))
        repeated = service.report_install(self.failed(name="u", stage="installer"))
        after_failure = [e["type"] for e in self.events()]

        retried = service.report_install({"kind": "progress", "stage": "late-commands", "name": "u"})

        entry = self.queue()[0]
        for key in ("failed_at", "failure_reason", "stage"):
            self.assertNotIn(key, entry)
        self.assertEqual(after_failure, ["install-failed"], "a repeated failure must not add an event")
        self.assertEqual([e["type"] for e in self.events()], ["install-failed", "install-progress"])
        self.assertEqual((repeated, retried), ({"result": "duplicate"}, {"result": "recorded"}))

    def test_a_broken_event_journal_never_loses_or_repeats_a_failure(self):
        attempts = []

        def broken(event_type, data):
            attempts.append(event_type)
            raise OSError("journal unwritable")

        self.seed([{"name": "m", "assigned": True, "mac": MAC}])
        self.write_info(MAC, name="m", attempt=1)
        service = svc.ProvisionService(self.queue_dir, hub=self.hub, now=lambda: T0, guard_dir=self.guard_dir, emit=broken)

        first = service.report_install(self.failed(mac=MAC))
        recorded = self.info()
        second = service.report_install(self.failed(mac=MAC))

        self.assertIn("failed_at", recorded)
        self.assertEqual(attempts, ["install-failed"], "the repeated report must not try to emit again")
        self.assertEqual((first, second), ({"result": "recorded"}, {"result": "duplicate"}))


if __name__ == "__main__":
    unittest.main()
