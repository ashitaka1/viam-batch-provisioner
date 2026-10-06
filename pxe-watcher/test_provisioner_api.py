"""HTTP and SSE tests for the provisioner API against a real server on an
ephemeral port.

These test our error mapping and the SSE replay/live/keepalive/shutdown
behaviour, not http.server itself.
"""

import http.client
import json
import shutil
import socket
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
import provisioner_api  # noqa: E402
import provisioner_service  # noqa: E402

MAC = "aa:bb:cc:dd:ee:ff"
T0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
CREDS = {"cloud": {"id": "part-1", "secret": "s3cr3t"}}
PROBES = {"http": lambda: "up", "dnsmasq": lambda: "down", "watcher": lambda: "unknown"}


class LiveServer:
    """A provisioner API bound to 127.0.0.1:0 over a temporary repo layout."""

    def __init__(self, keepalive=0.2):
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.queue_dir = self.root / "http-server" / "machines"
        self.queue_dir.mkdir(parents=True)
        self.guard_dir = self.root / "netboot" / "grub" / "provisioned"
        (self.root / "logs").mkdir()
        self.journal_path = self.root / "logs" / "events.jsonl"
        self.journal = event_journal.EventJournal(self.journal_path, now=lambda: T0)
        self.hub = event_hub.EventHub(self.journal_path, poll=0.02)
        self.hub.start()
        self.service = provisioner_service.ProvisionService(self.queue_dir, hub=self.hub, now=lambda: T0, emit=self.journal.emit)
        self.server = provisioner_api.make_server(
            self.service, self.hub, "127.0.0.1", 0,
            server_name="test-server", probes=PROBES, now=lambda: T0, keepalive=keepalive,
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def reset_disk(self):
        for child in self.queue_dir.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
        if self.guard_dir.exists():
            shutil.rmtree(self.guard_dir)

    def emit(self, count=1):
        return [self.journal.emit("machine-assigned", {"name": f"t-{i}", "mac": MAC}) for i in range(count)]

    def close(self):
        self.hub.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        self._tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        data = None
        hdrs = dict(headers or {})
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            hdrs.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=data, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        parsed = json.loads(raw) if raw and resp.getheader("Content-Type", "").startswith("application/json") else raw
        return resp.status, dict(resp.getheaders()), parsed

    def raw(self, text):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        sock.sendall(text.encode())
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        sock.close()
        return b"".join(chunks).decode(errors="replace")

    def open_stream(self, last_event_id=None, timeout=5):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        headers = {} if last_event_id is None else {"Last-Event-ID": str(last_event_id)}
        conn.request("GET", "/api/v1/events", headers=headers)
        resp = conn.getresponse()
        return SseReader(conn, resp)


class SseReader:
    def __init__(self, conn, resp):
        self.conn = conn
        self.resp = resp
        self.status = resp.status

    def readline(self):
        return self.resp.fp.readline().decode()

    def next_frame(self):
        """Return the next event frame as a dict with id/event/data; comments and retry lines are skipped."""
        frame = {}
        while True:
            line = self.readline()
            if line == "":
                return None
            line = line.rstrip("\n")
            if line == "":
                if frame:
                    return frame
                continue
            if line.startswith(":") or line.startswith("retry:"):
                continue
            key, _, value = line.partition(":")
            frame[key] = value.strip()

    def close(self):
        self.conn.close()


def error_code(body):
    return body["error"]["code"]


class ApiServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.live = LiveServer()

    @classmethod
    def tearDownClass(cls):
        cls.live.close()

    def setUp(self):
        self.live.reset_disk()

    def test_error_mapping(self):
        live = self.live
        live.service.provision([{"name": "busy"}])
        (live.queue_dir / "queue.json").write_text(json.dumps([{"name": "busy", "assigned": True, "mac": MAC}]))

        rows = [
            ("invalid json", "POST", "/api/v1/provision", b"{not json", 400, "invalid-json"),
            ("unknown name", "GET", "/api/v1/queue/nope", None, 404, "not-found"),
            ("bad name", "GET", "/api/v1/queue/..", None, 400, "invalid-name"),
            ("delete assigned", "DELETE", "/api/v1/queue/busy", None, 409, "already-assigned"),
            ("too large", "POST", "/api/v1/provision", b"[" + b" " * (5 * 1024 * 1024) + b"]", 413, "payload-too-large"),
        ]
        for label, method, path, body, status, code in rows:
            with self.subTest(case=label):
                got_status, _, got_body = live.request(method, path, body=body)
                self.assertEqual((got_status, error_code(got_body)), (status, code), f"{label}: {got_body}")

        with self.subTest(case="wrong method"):
            status, headers, body = live.request("PUT", "/api/v1/queue")
            self.assertEqual((status, error_code(body)), (405, "method-not-allowed"))
            self.assertIn("GET", headers.get("Allow", ""))

        with self.subTest(case="missing content-length"):
            text = live.raw("POST /api/v1/provision HTTP/1.0\r\nHost: x\r\n\r\n")
            self.assertIn(" 411 ", text.splitlines()[0])
            self.assertIn("length-required", text)

        with self.subTest(case="corrupt queue"):
            (live.queue_dir / "queue.json").write_text("{not json")
            status, _, body = live.request("GET", "/api/v1/queue")
            self.assertEqual((status, error_code(body)), (503, "queue-unreadable"))

    def test_sse_replay_then_live_has_no_gap_or_duplicate(self):
        live = self.live
        first = live.emit(4)
        base = first[0]["id"]
        self.assertTrue(wait_until(lambda: live.hub.last_id == first[-1]["id"]))

        reader = live.open_stream(last_event_id=base)
        try:
            self.assertEqual(reader.status, 200)
            ids = []
            while len(ids) < 3:
                frame = reader.next_frame()
                self.assertIsNotNone(frame, "stream ended during replay")
                ids.append(int(frame["id"]))
            more = live.emit(2)
            while len(ids) < 5:
                frame = reader.next_frame()
                self.assertIsNotNone(frame, "stream ended before live events arrived")
                ids.append(int(frame["id"]))
                self.assertEqual(frame["event"], "machine-assigned")
            self.assertEqual(ids, list(range(base + 1, more[-1]["id"] + 1)))
            data = json.loads(frame["data"])
            self.assertEqual((data["id"], data["type"], data["name"]), (more[-1]["id"], "machine-assigned", "t-1"))
        finally:
            reader.close()

    def test_sse_resync_when_cursor_ahead_of_journal(self):
        live = self.live
        live.emit(1)
        latest = live.journal.emit("machine-assigned", {"name": "t", "mac": MAC})["id"]
        self.assertTrue(wait_until(lambda: live.hub.last_id == latest))

        reader = live.open_stream(last_event_id=latest + 100)
        try:
            frame = reader.next_frame()
            self.assertEqual(frame["event"], "resync")
            self.assertNotIn("id", frame)
            self.assertEqual(json.loads(frame["data"]), {"type": "resync", "latest_id": latest})
            nxt = live.emit(1)[0]
            frame = reader.next_frame()
            self.assertEqual(int(frame["id"]), nxt["id"])
        finally:
            reader.close()

    def test_sse_keepalive_comment_on_idle(self):
        reader = self.live.open_stream()
        try:
            deadline = time.monotonic() + 3
            seen = []
            while time.monotonic() < deadline:
                line = reader.readline()
                seen.append(line)
                if line.startswith(": keepalive"):
                    break
            else:
                self.fail(f"no keepalive within 3s: {seen}")
        finally:
            reader.close()


class ShutdownTest(unittest.TestCase):
    def test_sse_shutdown_closes_open_stream(self):
        live = LiveServer()
        reader = live.open_stream()
        try:
            self.assertTrue(reader.readline().startswith("retry:"))
            started = time.monotonic()
            provisioner_api.stop(live.server, live.hub)
            while True:
                line = reader.readline()
                if line == "":
                    break
                self.assertLess(time.monotonic() - started, 3, "stream did not end after shutdown")
            self.assertLess(time.monotonic() - started, 3)
            live.thread.join(3)
            self.assertFalse(live.thread.is_alive())
        finally:
            reader.close()
            live.server.server_close()
            live._tmp.cleanup()


class InstallReportTest(unittest.TestCase):
    """The installer's report endpoint, end to end through the live server."""

    def setUp(self):
        self.live = LiveServer()
        self.live.reset_disk()

    def tearDown(self):
        self.live.close()

    def assign_pxe(self, name="r-1", mac=MAC, guard=True):
        """An assigned PXE machine, optionally already past its hostname fetch."""
        live = self.live
        (live.queue_dir / "queue.json").write_text(json.dumps([{"name": name, "assigned": True, "mac": mac}]))
        (live.queue_dir / mac).mkdir(exist_ok=True)
        (live.queue_dir / mac / "machine-info.json").write_text(json.dumps(
            {"name": name, "mac": mac, "assigned_at": T0.isoformat(timespec="seconds"), "attempt": 1}))
        if guard:
            live.guard_dir.mkdir(parents=True, exist_ok=True)
            (live.guard_dir / f"{mac}.cfg").write_text("exit\n")

    def journal(self):
        path = self.live.journal_path
        return event_journal.read_all(path) if path.exists() else []

    def test_a_failure_report_shows_up_in_the_queue_and_event_stream(self):
        live = self.live
        self.assign_pxe()
        report = {"kind": "failed", "stage": "tooling", "mac": MAC, "reason": "curl failed"}

        status, _, body = live.request("POST", "/api/v1/install-reports", body=report)
        _, _, entry = live.request("GET", "/api/v1/queue/r-1")
        after_first = [r["type"] for r in self.journal()]
        repeat_status, _, repeat_body = live.request("POST", "/api/v1/install-reports", body=report)
        after_repeat = [r["type"] for r in self.journal()]
        reader = live.open_stream(last_event_id=0)
        try:
            frame = reader.next_frame()
        finally:
            reader.close()

        self.assertEqual((entry["status"], entry["failure_reason"], entry["stage"]), ("failed", "curl failed", "tooling"))
        self.assertEqual(after_first, ["install-failed"])
        self.assertEqual(after_repeat, ["install-failed"], "a repeated report must not add an event")
        self.assertEqual(frame["event"], "install-failed")
        self.assertEqual((status, body), (200, {"result": "recorded"}))
        self.assertEqual((repeat_status, repeat_body), (200, {"result": "duplicate"}))

    def test_usb_failures_are_reported_without_a_watcher(self):
        live = self.live
        (live.queue_dir / "queue.json").write_text(json.dumps([{"name": "u-1", "assigned": True, "flashed_via": "usb"}]))

        status, _, body = live.request("POST", "/api/v1/install-reports", body={"kind": "failed", "stage": "installer", "name": "u-1"})
        _, _, entry = live.request("GET", "/api/v1/queue/u-1")
        records = self.journal()

        self.assertEqual((entry["status"], entry["flashed_via"]), ("failed", "usb"))
        self.assertEqual([r["data"]["name"] for r in records], ["u-1"])
        self.assertNotIn("mac", records[0]["data"])
        self.assertEqual((status, body), (200, {"result": "recorded"}))

    def test_bad_requests_get_the_right_http_error(self):
        live = self.live
        cases = [
            ("invalid fields", {"kind": "nope"}, 400, "invalid-request"),
            ("not json", b"nope", 400, "invalid-json"),
            ("unknown machine", {"kind": "progress", "stage": "identity", "mac": MAC}, 404, "not-found"),
            ("body over the report limit", b" " * (provisioner_api.MAX_REPORT_BODY + 1), 413, "payload-too-large"),
        ]
        for label, payload, expected_status, expected_code in cases:
            with self.subTest(label):
                status, _, body = live.request("POST", "/api/v1/install-reports", body=payload)
                self.assertEqual((status, error_code(body)), (expected_status, expected_code))

        with self.subTest("wrong method"):
            status, headers, body = live.request("GET", "/api/v1/install-reports")
            self.assertEqual((status, headers["Allow"], error_code(body)), (405, "POST", "method-not-allowed"))


def wait_until(pred, timeout=5.0, interval=0.01):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return pred()


if __name__ == "__main__":
    unittest.main()
