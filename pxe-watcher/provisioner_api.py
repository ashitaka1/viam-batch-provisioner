#!/usr/bin/env python3
"""REST + SSE server for the provisioner, implementing openapi/provisioner.yaml
on the standard library.

Usage:
    provisioner_api.py [--port 8235] [--bind 0.0.0.0] [--queue-dir DIR]
                       [--events-log FILE] [--http-port 8234] [--interface IFACE]

Runs as the operator (not root): it only reads watcher state and writes the
queue through queue_store.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from typing import Callable, Dict, Optional
from urllib.parse import parse_qs, unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event_hub  # noqa: E402
import provisioner_service as svc  # noqa: E402
import watcher  # noqa: E402

DEFAULT_PORT = 8235
DEFAULT_HTTP_PORT = 8234
MAX_BODY = 5 * 1024 * 1024

ROUTES = [
    ("POST", "/api/v1/provision", "provision"),
    ("GET", "/api/v1/queue", "list_queue"),
    ("GET", "/api/v1/queue/{name}", "get_entry"),
    ("DELETE", "/api/v1/queue/{name}", "remove_entry"),
    ("GET", "/api/v1/status", "status"),
    ("GET", "/api/v1/events", "events"),
]


def _compile(template: str):
    return re.compile("^" + re.sub(r"\{(\w+)\}", r"(?P<\1>[^/]+)", template) + "$")


_COMPILED = [(method, template, _compile(template), handler) for method, template, handler in ROUTES]


class HttpError(svc.ServiceError):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code


def server_status(server) -> dict:
    hub = server.hub
    services = {}
    for name in ("http", "dnsmasq", "watcher"):
        probe = server.probes.get(name)
        try:
            services[name] = probe() if probe else "unknown"
        except Exception:
            services[name] = "unknown"
    body = {
        "api_version": "v1",
        "server_name": server.advertised_name,
        "time": server.now().isoformat(timespec="seconds"),
        "services": services,
        "last_event_id": hub.last_id if hub is not None else 0,
    }
    try:
        body["queue"] = svc.counts(server.service.entries())
    except svc.QueueUnreadable:
        pass
    try:
        address = server.address_fn() if server.address_fn else None
    except Exception:
        address = None
    if address:
        body["address"] = address
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    timeout = 10

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s %s\n" % (datetime.now().strftime("%H:%M:%S"), self.address_string(), fmt % args))

    def _handle(self):
        self._dispatch(self.command)

    do_GET = do_POST = do_DELETE = do_PUT = do_PATCH = do_HEAD = do_OPTIONS = _handle

    def _dispatch(self, method: str) -> None:
        url = urlsplit(self.path)
        allowed = []
        for route_method, _template, pattern, handler in _COMPILED:
            match = pattern.match(url.path)
            if not match:
                continue
            allowed.append(route_method)
            if route_method != method:
                continue
            try:
                getattr(self, "_h_" + handler)({k: unquote(v) for k, v in match.groupdict().items()}, url)
            except svc.ServiceError as e:
                self._send_json(e.status, e.body())
            except OSError:
                pass
            except Exception as e:  # never let a handler kill the server
                self.log_message("ERROR %s", e)
                self._send_error(500, "internal", str(e))
            return
        if allowed:
            self._send_error(405, "method-not-allowed", f"{method} not allowed", extra={"Allow": ", ".join(sorted(set(allowed)))})
        else:
            self._send_error(404, "not-found", f"no route for {url.path}")

    def _send_error(self, status: int, code: str, message: str, extra: Optional[Dict[str, str]] = None) -> None:
        self._send_json(status, {"error": {"code": code, "message": message}}, extra=extra)

    def _send_json(self, status: int, body: dict, extra: Optional[Dict[str, str]] = None) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_empty(self, status: int) -> None:
        self.send_response(status)
        self.end_headers()

    def _read_json(self):
        length = self.headers.get("Content-Length")
        if length is None:
            raise HttpError(411, "length-required", "Content-Length is required")
        try:
            size = int(length)
            if size < 0:
                raise ValueError
        except ValueError:
            raise HttpError(400, "invalid-request", "Content-Length is not a non-negative integer")
        if size > MAX_BODY:
            self._drain(size)
            raise HttpError(413, "payload-too-large", f"body exceeds {MAX_BODY} bytes")
        raw = self.rfile.read(size)
        try:
            return json.loads(raw)
        except ValueError:
            raise HttpError(400, "invalid-json", "body is not valid JSON")

    def _drain(self, size: int) -> None:
        remaining = size
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)

    def _h_provision(self, _params, _url):
        body = self._read_json()
        results = self.server.service.provision(body)
        self._send_json(200, {"results": results})

    def _h_list_queue(self, _params, _url):
        self._send_json(200, self.server.service.list_queue())

    def _h_get_entry(self, params, _url):
        self._send_json(200, self.server.service.get_entry(params["name"]))

    def _h_remove_entry(self, params, _url):
        self.server.service.remove(params["name"])
        self._send_empty(204)

    def _h_status(self, _params, _url):
        self._send_json(200, server_status(self.server))

    def _h_events(self, _params, url):
        hub = self.server.hub
        raw = self.headers.get("Last-Event-ID")
        if raw is None:
            raw = parse_qs(url.query).get("last_event_id", [None])[0]
        cursor = None
        if raw is not None:
            try:
                cursor = int(raw)
                if cursor < 0:
                    raise ValueError
            except ValueError:
                raise HttpError(400, "invalid-request", "Last-Event-ID must be a non-negative integer")
        if not self.server.streams.acquire(blocking=False):
            raise HttpError(503, "too-many-streams", "too many open event streams")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"retry: 3000\n\n")
            self.wfile.flush()

            if cursor is None:
                cursor = hub.last_id
            else:
                cursor = self._deliver(hub, cursor)

            keepalive = self.server.keepalive
            last_write = time.monotonic()
            while not hub.stopped:
                if hub.wait(cursor, min(1.0, keepalive)):
                    cursor = self._deliver(hub, cursor)
                    last_write = time.monotonic()
                elif time.monotonic() - last_write >= keepalive:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_write = time.monotonic()
        except OSError:
            return
        finally:
            self.server.streams.release()

    def _deliver(self, hub, cursor: int) -> int:
        kind, payload = hub.events_after(cursor)
        if kind == "resync":
            self._write_frame(None, "resync", {"type": "resync", "latest_id": payload})
            return payload
        for record in payload:
            self._write_frame(record["id"], record["type"], record["data"])
            cursor = record["id"]
        return cursor

    def _write_frame(self, event_id: Optional[int], event: str, data: dict) -> None:
        lines = []
        if event_id is not None:
            lines.append(f"id: {event_id}")
        lines.append(f"event: {event}")
        lines.append("data: " + json.dumps(data, separators=(",", ":")))
        self.wfile.write(("\n".join(lines) + "\n\n").encode())
        self.wfile.flush()


class ApiServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind resolves the bind address with getfqdn(),
        # a reverse DNS lookup that can stall for 30s on networks without
        # PTR records. The name is only used for the Server header.
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def make_server(service, hub, host: str = "0.0.0.0", port: int = DEFAULT_PORT, *,
                server_name: Optional[str] = None, probes: Optional[Dict[str, Callable[[], str]]] = None,
                now: Optional[Callable[[], datetime]] = None, keepalive: float = 15.0, max_streams: int = 64,
                address_fn: Optional[Callable[[], Optional[str]]] = None) -> ThreadingHTTPServer:
    server = ApiServer((host, port), Handler)
    server.service = service
    server.hub = hub
    server.advertised_name = server_name or socket.gethostname()
    server.probes = probes or {}
    server.now = now or (lambda: datetime.now(timezone.utc))
    server.keepalive = keepalive
    server.streams = threading.BoundedSemaphore(max_streams)
    server.address_fn = address_fn
    return server


def _tcp_probe(port: int) -> Callable[[], str]:
    def probe() -> str:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return "up"
        except OSError:
            return "down"
    return probe


def _pgrep_probe(*args: str) -> Callable[[], str]:
    def probe() -> str:
        try:
            rc = subprocess.run(["pgrep", *args], capture_output=True, timeout=2).returncode
        except (OSError, subprocess.TimeoutExpired):
            return "unknown"
        return "up" if rc == 0 else "down"
    return probe


def default_probes(http_port: int) -> Dict[str, Callable[[], str]]:
    return {
        "http": _tcp_probe(http_port),
        "dnsmasq": _pgrep_probe("-x", "dnsmasq"),
        "watcher": _pgrep_probe("-f", "pxe-watcher/watcher.py"),
    }


def address_resolver(repo: Path, interface: Optional[str], http_port: int) -> Callable[[], Optional[str]]:
    """host:port targets fetch from: the baked-in interface's address when
    the daemon knows it, else the address USB sticks were flashed with,
    else the default-route interface."""
    saved = repo / "config" / ".server-address"

    def resolve() -> Optional[str]:
        iface = interface
        if iface is None and saved.exists():
            return saved.read_text().strip() or None
        iface = iface or watcher.detect_interface()
        if iface is None:
            return None
        try:
            if platform.system() == "Darwin":
                ip = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True, timeout=2).stdout.strip()
            else:
                out = subprocess.run(["ip", "-o", "-4", "addr", "show", iface], capture_output=True, text=True, timeout=2).stdout
                ip = out.split()[3].split("/")[0] if out.split() else ""
        except (OSError, subprocess.TimeoutExpired, IndexError):
            return None
        return f"{ip}:{http_port}" if ip else None

    return resolve


def default_server_name() -> str:
    if platform.system() == "Darwin":
        try:
            name = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=2).stdout.strip()
            if name:
                return name
        except (OSError, subprocess.TimeoutExpired):
            pass
    return socket.gethostname().split(".")[0]


def stop(server, hub) -> None:
    """Release open SSE streams, then stop accepting connections."""
    hub.stop()
    threading.Thread(target=server.shutdown, daemon=True).start()


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Provisioner REST + SSE API")
    parser.add_argument("--port", type=int, default=int(os.environ.get("API_PORT") or DEFAULT_PORT))
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--queue-dir", type=Path, default=repo / "http-server" / "machines")
    parser.add_argument("--events-log", type=Path, default=repo / "logs" / "events.jsonl")
    parser.add_argument("--http-port", type=int, default=int(os.environ.get("HTTP_PORT") or DEFAULT_HTTP_PORT),
                        help="port of the nginx file server, for /status and the advertised address")
    parser.add_argument("--interface", default=None, help="serving interface, for the advertised address")
    parser.add_argument("--server-name", default=None)
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass

    hub = event_hub.EventHub(args.events_log)
    hub.start()
    service = svc.ProvisionService(args.queue_dir, hub=hub)
    try:
        server = make_server(
            service, hub, args.bind, args.port,
            server_name=args.server_name or default_server_name(),
            probes=default_probes(args.http_port),
            address_fn=address_resolver(repo, args.interface, args.http_port),
        )
    except OSError as e:
        print(f"ERROR: cannot listen on {args.bind}:{args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    def on_signal(_signum, _frame):
        stop(server, hub)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    print(f"Provisioner API listening on {args.bind}:{args.port}")
    print(f"  Queue directory: {args.queue_dir}")
    print(f"  Events log:      {args.events_log}")
    server.serve_forever()
    server.server_close()


if __name__ == "__main__":
    main()
