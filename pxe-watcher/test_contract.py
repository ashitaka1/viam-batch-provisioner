"""Contract tests: the Python server against openapi/provisioner.yaml.

The route check needs no dependencies. Schema validation needs PyYAML and
jsonschema from the project venv (`.venv/bin/pip install pyyaml jsonschema`);
`just test` prefers the venv interpreter so it runs there.
"""

import json
import re
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_journal  # noqa: E402
import provisioner_api  # noqa: E402
import watcher  # noqa: E402
from test_provisioner_api import LiveServer, MAC, CREDS  # noqa: E402

SPEC_PATH = Path(__file__).resolve().parent.parent / "openapi" / "provisioner.yaml"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)

try:
    import jsonschema
    import yaml
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False
    print(
        "\nCONTRACT TEST SKIPPED: PyYAML/jsonschema not importable by this interpreter.\n"
        "  Install into the project venv: .venv/bin/pip install pyyaml jsonschema\n",
        file=sys.stderr,
    )


def spec_route_pairs(text):
    """(METHOD, path) pairs from the `paths:` block. Assumes the spec's two-space
    indentation: paths at indent 2, operations at indent 4."""
    pairs = set()
    in_paths = False
    current = None
    for line in text.splitlines():
        if line.startswith("paths:"):
            in_paths = True
            continue
        if in_paths and line and not line.startswith(" "):
            break
        if not in_paths:
            continue
        m = re.match(r"^  (/\S+):\s*$", line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"^    (get|post|put|patch|delete):\s*$", line)
        if m and current:
            pairs.add((m.group(1).upper(), current))
    return pairs


class RoutesMatchSpecTest(unittest.TestCase):
    def test_routes_match_spec_paths(self):
        spec_pairs = spec_route_pairs(SPEC_PATH.read_text())
        api_pairs = {(method, template) for method, template, _ in provisioner_api.ROUTES}
        self.assertTrue(spec_pairs, "no routes parsed from the spec; indentation assumption broken?")
        self.assertEqual(api_pairs, spec_pairs)


@unittest.skipUnless(HAVE_DEPS, "PyYAML and jsonschema required (.venv/bin/pip install pyyaml jsonschema)")
class SchemaValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = yaml.safe_load(SPEC_PATH.read_text())
        cls.live = LiveServer()

    @classmethod
    def tearDownClass(cls):
        cls.live.close()

    def validate(self, obj, schema_name):
        schema = {"$ref": f"#/components/schemas/{schema_name}", "components": self.spec["components"]}
        jsonschema.Draft7Validator(schema).validate(obj)

    def test_responses_validate_against_spec(self):
        live = self.live
        live.reset_disk()

        status, _, body = live.request("POST", "/api/v1/provision", body=[{"name": "c-1", "credentials": CREDS}, {"name": "c-2"}])
        self.assertEqual(status, 200)
        self.validate(body, "ProvisionResponse")

        status, _, body = live.request("GET", "/api/v1/queue")
        self.assertEqual(status, 200)
        self.validate(body, "QueueList")

        status, _, body = live.request("GET", "/api/v1/queue/c-1")
        self.assertEqual(status, 200)
        self.validate(body, "QueueEntry")

        status, _, body = live.request("GET", "/api/v1/status")
        self.assertEqual(status, 200)
        self.validate(body, "ServerStatus")

        status, _, body = live.request("DELETE", "/api/v1/queue/c-2")
        self.assertEqual((status, body), (204, b""))

        for method, path, payload in [
            ("GET", "/api/v1/queue/missing", None),
            ("POST", "/api/v1/provision", [{"name": "Bad"}]),
            ("POST", "/api/v1/provision", b"nope"),
        ]:
            with self.subTest(path=path, payload=str(payload)[:30]):
                status, _, body = live.request(method, path, body=payload)
                self.assertGreaterEqual(status, 400)
                self.validate(body, "Error")

    def test_install_reports_validate_against_spec(self):
        live = self.live
        live.reset_disk()
        live.journal_path.unlink(missing_ok=True)
        (live.queue_dir / "queue.json").write_text(json.dumps([
            {"name": "c-1", "assigned": True, "mac": MAC},
            {"name": "u-1", "assigned": True, "flashed_via": "usb"},
        ]))
        (live.queue_dir / MAC).mkdir()
        (live.queue_dir / MAC / "machine-info.json").write_text(json.dumps(
            {"name": "c-1", "mac": MAC, "assigned_at": T0.isoformat(timespec="seconds"), "attempt": 1}))
        live.guard_dir.mkdir(parents=True, exist_ok=True)
        (live.guard_dir / f"{MAC}.cfg").write_text("exit\n")

        reports = [
            {"kind": "progress", "stage": "tooling", "mac": MAC},
            {"kind": "failed", "stage": "tooling", "mac": MAC, "reason": "x" * 500},
            {"kind": "failed", "stage": "installer", "name": "u-1"},
        ]
        for report in reports:
            with self.subTest(report=f"{report['kind']} {report.get('mac') or report.get('name')}"):
                status, _, body = live.request("POST", "/api/v1/install-reports", body=report)
                self.assertEqual(status, 200)
                self.validate(body, "InstallReportResult")

        status, _, body = live.request("GET", "/api/v1/queue")
        self.assertEqual(status, 200)
        self.validate(body, "QueueList")
        self.assertEqual(sorted(e["status"] for e in body["entries"]), ["failed", "failed"])

        status, _, body = live.request("GET", "/api/v1/status")
        self.assertEqual(status, 200)
        self.validate(body, "ServerStatus")
        self.assertEqual(body["queue"]["failed"], 2)

        records = event_journal.read_all(live.journal_path)
        self.assertEqual([r["type"] for r in records], ["install-progress", "install-failed", "install-failed"])
        for record in records:
            with self.subTest(event=record["type"], mac=record["data"].get("mac")):
                self.validate(record["data"], "MachineEvent")

    def test_a_failed_boot_validates_against_spec(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue_dir = root / "http-server" / "machines"
            queue_dir.mkdir(parents=True)
            (root / "logs").mkdir()
            (queue_dir / "queue.json").write_text(json.dumps([{"name": "e-1", "assigned": False}]))
            journal = event_journal.EventJournal(root / "logs" / "events.jsonl", now=lambda: T0)
            clock = {"now": T0}
            tracker = watcher.PxeTracker(queue_dir, now=lambda: clock["now"], log=lambda *_: None, emit=journal.emit)

            tracker.on_pxe(MAC)
            clock["now"] = T0 + timedelta(minutes=5)
            tracker.on_pxe(MAC)  # booted again before the installer ever reported

            records = [event_journal.parse_line(l) for l in (root / "logs" / "events.jsonl").read_text().splitlines()]
            self.assertEqual([r["type"] for r in records], ["machine-assigned", "install-failed", "machine-assigned"])
            for record in records:
                with self.subTest(type=record["type"]):
                    self.validate(record["data"], "MachineEvent")

    def test_events_validate_against_spec(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue_dir = root / "http-server" / "machines"
            queue_dir.mkdir(parents=True)
            (root / "logs").mkdir()
            (queue_dir / "queue.json").write_text(json.dumps([{"name": "e-1", "assigned": False}]))
            journal = event_journal.EventJournal(root / "logs" / "events.jsonl", now=lambda: T0)
            clock = {"now": T0}
            tracker = watcher.PxeTracker(queue_dir, now=lambda: clock["now"], log=lambda *_: None, emit=journal.emit)

            tracker.on_pxe(MAC)
            tracker.on_hostname_fetch(MAC)
            clock["now"] = T0 + timedelta(minutes=5)
            tracker.on_pxe(MAC)

            records = [event_journal.parse_line(l) for l in (root / "logs" / "events.jsonl").read_text().splitlines()]
            self.assertEqual([r["type"] for r in records],
                             ["machine-assigned", "install-started", "guard-installed", "install-complete"])
            for record in records:
                with self.subTest(type=record["type"]):
                    self.validate(record["data"], "MachineEvent")
            self.validate({"type": "resync", "latest_id": 4}, "Resync")


if __name__ == "__main__":
    unittest.main()
