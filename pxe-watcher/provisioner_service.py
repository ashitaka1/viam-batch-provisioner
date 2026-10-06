#!/usr/bin/env python3
"""Provisioning operations behind the REST API: validate requests, stage
credentials under the queue lock, derive queue status from disk, remove
unassigned entries.

Status comes from disk alone (queue.json, machine-info.json, the GRUB
guard), so `just reset`, `just clean` and `just unguard` are reflected on
the next read without a restart.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import queue_store  # noqa: E402
import watcher  # noqa: E402

NAME_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
MAX_ITEMS = 500
STATUSES = ("queued", "flashed", "assigned", "installing", "installed", "failed")

# Install reports from the target. A stage names the section of the installer
# that was entered last. `installer` (before late-commands began) only ever
# appears on a failure, `done` only on progress, and `unknown` is set by the
# server when a timeout fires with nothing on record, so a target can't send it.
PROGRESS_STAGES = ("late-commands", "identity", "tooling", "tailscale", "done")
FAILURE_STAGES = ("installer", "late-commands", "identity", "tooling", "tailscale")
MAX_REASON = 500
DEFAULT_REASON = "installer reported a failure"


class ServiceError(Exception):
    status = 500
    code = "internal"

    def __init__(self, message: str, details: Optional[list] = None):
        super().__init__(message)
        self.message = message
        self.details = details or []

    def body(self) -> dict:
        error = {"code": self.code, "message": self.message}
        if self.details:
            error["details"] = self.details
        return {"error": error}


class ValidationError(ServiceError):
    status = 400
    code = "invalid-request"


class InvalidName(ServiceError):
    status = 400
    code = "invalid-name"


class NotFound(ServiceError):
    status = 404
    code = "not-found"


class Conflict(ServiceError):
    status = 409
    code = "already-assigned"


class QueueUnreadable(ServiceError):
    status = 503
    code = "queue-unreadable"


class QueueLocked(ServiceError):
    status = 503
    code = "queue-locked"


class StageFailed(ServiceError):
    status = 500
    code = "stage-failed"


def valid_name(name) -> bool:
    return isinstance(name, str) and NAME_RE.fullmatch(name) is not None


def safe_lookup_name(name: str) -> bool:
    """Path-safe enough to look up or remove. Looser than valid_name so
    entries queued by the bash scripts with other prefixes stay reachable."""
    return bool(name) and len(name) <= 253 and "/" not in name and name not in (".", "..") and name.isprintable()


def _valid_credentials(credentials) -> bool:
    if not isinstance(credentials, dict):
        return False
    cloud = credentials.get("cloud")
    if not isinstance(cloud, dict):
        return False
    return all(isinstance(cloud.get(k), str) and cloud.get(k) for k in ("id", "secret"))


def validate_provision(body) -> list:
    """Normalized [{name, credentials}] or ValidationError with per-item details."""
    if not isinstance(body, list):
        raise ValidationError("request body must be a JSON array of machines", [{"message": "body must be an array"}])
    if not body:
        raise ValidationError("at least one machine is required", [{"message": "body is empty"}])
    if len(body) > MAX_ITEMS:
        raise ValidationError(f"at most {MAX_ITEMS} machines per request", [{"message": f"{len(body)} items"}])

    details = []
    items = []
    for index, item in enumerate(body):
        if not isinstance(item, dict):
            details.append({"index": index, "message": "item must be an object"})
            continue
        name = item.get("name")
        if not valid_name(name):
            details.append({"index": index, "field": "name", "message": "must match ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"})
        credentials = item.get("credentials")
        if credentials is not None and not _valid_credentials(credentials):
            details.append({"index": index, "field": "credentials", "message": "must be a viam.json object with cloud.id and cloud.secret"})
        items.append({"name": name, "credentials": credentials})
    if details:
        raise ValidationError("invalid provision request", details)
    return items


def sanitize_reason(text) -> str:
    """A failure reason that is safe to journal: control characters become
    spaces, whitespace collapses, the length is capped, and an empty reason
    is replaced with readable text."""
    if text is None:
        return DEFAULT_REASON
    cleaned = " ".join("".join(c if c.isprintable() else " " for c in text).split())
    return cleaned[:MAX_REASON] or DEFAULT_REASON


def validate_report(body) -> dict:
    """A normalized {kind, stage, name, mac, reason} install report, or
    ValidationError with per-field details. The target is untrusted input."""
    if not isinstance(body, dict):
        raise ValidationError("request body must be a JSON object", [{"message": "body must be an object"}])

    details = []
    kind = body.get("kind")
    if kind not in ("progress", "failed"):
        details.append({"field": "kind", "message": "must be progress or failed"})
    else:
        allowed = PROGRESS_STAGES if kind == "progress" else FAILURE_STAGES
        if body.get("stage") not in allowed:
            details.append({"field": "stage", "message": "for " + kind + " must be one of " + ", ".join(allowed)})

    name, mac = body.get("name"), body.get("mac")
    if (name is None) == (mac is None):
        details.append({"message": "exactly one of name and mac is required"})
    elif name is not None and not (isinstance(name, str) and safe_lookup_name(name)):
        details.append({"field": "name", "message": "is not a valid machine name"})
    elif mac is not None and not (isinstance(mac, str) and re.fullmatch(watcher.MAC_RE, mac)):
        details.append({"field": "mac", "message": "must be a lowercase colon-separated MAC address"})

    reason = body.get("reason")
    if kind == "failed" and reason is not None and not isinstance(reason, str):
        details.append({"field": "reason", "message": "must be a string"})

    if details:
        raise ValidationError("invalid install report", details)
    return {
        "kind": kind, "stage": body["stage"], "name": name, "mac": mac,
        "reason": sanitize_reason(reason) if kind == "failed" else None,
    }


def write_slot_file(slot_dir: Path, credentials: dict) -> None:
    """Write slot-<name>/viam.json atomically, mode 0644 like fetch-credentials.py's output."""
    queue_store.atomic_write_json(slot_dir / "viam.json", credentials)


def _copy_failure(out: dict, source: dict) -> None:
    for key in ("failed_at", "failure_reason", "stage"):
        if source.get(key):
            out[key] = source[key]


def derive_entry(queue_dir: Path, raw: dict, guard_dir: Optional[Path] = None) -> dict:
    """A QueueEntry for the API from a queue.json entry plus disk state."""
    queue_dir = Path(queue_dir)
    name = raw["name"]
    out = {"name": name}
    slot_id = raw.get("slot_id")
    has_credentials = bool(slot_id) and (queue_dir / slot_id / "viam.json").exists()
    mac = raw.get("mac")

    if not raw.get("assigned"):
        status = "queued"
    elif not mac:
        flashed_via = raw.get("flashed_via")
        if raw.get("failed_at"):
            # A failure removes the guard, so it has to outrank everything else.
            status = "failed"
            _copy_failure(out, raw)
        else:
            status = "flashed" if flashed_via == "usb" else "assigned"
        if flashed_via:
            out["flashed_via"] = flashed_via
    else:
        out["mac"] = mac
        has_credentials = has_credentials or (queue_dir / mac / "viam.json").exists()
        info = watcher.read_info(queue_dir, mac)
        if info is None or "assigned_at" not in info:
            status = "assigned"
        else:
            out["assigned_at"] = info["assigned_at"]
            guard = (guard_dir or watcher._guard_dir(queue_dir)) / f"{mac}.cfg"
            if info.get("failed_at"):
                # A failure removes the guard, which alone would read as "assigned".
                status = "failed"
                _copy_failure(out, info)
            elif not guard.exists():
                status = "assigned"
            elif info.get("completed_at"):
                status = "installed"
                out["completed_at"] = info["completed_at"]
            else:
                status = "installing"
                if info.get("stage"):
                    out["stage"] = info["stage"]

    out["status"] = status
    out["has_credentials"] = has_credentials
    return out


def counts(entries: list) -> dict:
    result = {status: 0 for status in STATUSES}
    for entry in entries:
        result[entry["status"]] += 1
    result["total"] = len(entries)
    return result


def _log(message: str) -> None:
    print(message, file=sys.stderr)


class ProvisionService:
    def __init__(self, queue_dir: Path, hub=None, now: Optional[Callable[[], datetime]] = None, guard_dir: Optional[Path] = None,
                 emit: Optional[Callable[[str, dict], None]] = None):
        self.queue_dir = Path(queue_dir)
        self.hub = hub
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.guard_dir = Path(guard_dir) if guard_dir else watcher._guard_dir(self.queue_dir)
        # Appends to the event journal. The API owns this so reports work under
        # `just serve-usb`, where no watcher runs.
        self.emit = emit

    def _read(self) -> list:
        try:
            return queue_store.read(self.queue_dir)
        except FileNotFoundError:
            return []
        except json.JSONDecodeError as e:
            raise QueueUnreadable(f"queue.json is not valid JSON: {e}")

    def provision(self, body) -> list:
        items = validate_provision(body)
        results = {}
        seen = set()
        to_add = []
        for index, item in enumerate(items):
            if item["name"] in seen:
                results[index] = {"name": item["name"], "result": "skipped", "reason": "duplicate-in-request"}
                continue
            seen.add(item["name"])
            to_add.append((index, item))

        by_name = {item["name"]: item for _, item in to_add}
        staged = []

        def stage(entry: dict) -> None:
            credentials = by_name[entry["name"]]["credentials"]
            if credentials is not None:
                slot_dir = self.queue_dir / entry["slot_id"]
                staged.append(slot_dir)
                write_slot_file(slot_dir, credentials)

        entries = []
        for _, item in to_add:
            entry = {"name": item["name"], "assigned": False}
            if item["credentials"] is not None:
                entry["slot_id"] = f"slot-{item['name']}"
            entries.append(entry)

        try:
            added, _skipped = queue_store.append(self.queue_dir, entries, stage=stage)
        except json.JSONDecodeError as e:
            raise QueueUnreadable(f"queue.json is not valid JSON: {e}")
        except TimeoutError as e:
            raise QueueLocked(str(e))
        except Exception as e:
            for slot_dir in staged:
                shutil.rmtree(slot_dir, ignore_errors=True)
            raise StageFailed(f"could not stage credentials: {e}")

        added_names = {e["name"] for e in added}
        for index, item in to_add:
            if item["name"] in added_names:
                results[index] = {"name": item["name"], "result": "added"}
            else:
                results[index] = {"name": item["name"], "result": "skipped", "reason": "already-queued"}
        return [results[i] for i in range(len(items))]

    def entries(self) -> list:
        return [derive_entry(self.queue_dir, raw, self.guard_dir) for raw in self._read()]

    def list_queue(self) -> dict:
        last_event_id = self.hub.last_id if self.hub is not None else 0
        return {"last_event_id": last_event_id, "entries": self.entries()}

    def get_entry(self, name: str) -> dict:
        if not safe_lookup_name(name):
            raise InvalidName(f"invalid machine name {name!r}")
        for raw in self._read():
            if raw["name"] == name:
                return derive_entry(self.queue_dir, raw, self.guard_dir)
        raise NotFound(f"{name} is not in the queue")

    def report_install(self, body) -> dict:
        """Record an installer's progress or failure report. Returns {"result": ...}
        where result is "recorded", "duplicate" or "ignored"."""
        report = validate_report(body)
        name, mac = report["name"], report["mac"]
        entries = self._read()
        if name is not None:
            entry = next((e for e in entries if e["name"] == name), None)
            if entry is None or not entry.get("assigned"):
                raise NotFound(f"{name} is not an assigned machine")
            mac = entry.get("mac")  # None for a USB-flashed machine
        else:
            entry = next((e for e in entries if e.get("assigned") and e.get("mac") == mac), None)
            if entry is None:
                raise NotFound(f"no machine is assigned to {mac}")
            name = entry["name"]

        try:
            if report["kind"] == "failed":
                result = watcher.apply_failure(
                    self.queue_dir, name=name, mac=mac, stage=report["stage"], reason=report["reason"],
                    source="installer", now=self.now(), emit=self.emit, log=_log)
            else:
                result = watcher.apply_progress(
                    self.queue_dir, name=name, mac=mac, stage=report["stage"],
                    now=self.now(), emit=self.emit, log=_log)
        except TimeoutError as e:
            raise QueueLocked(str(e))
        except json.JSONDecodeError as e:
            raise QueueUnreadable(f"queue.json is not valid JSON: {e}")
        if result == "unknown":
            raise NotFound(f"{name} has no install record")
        return {"result": result}

    def remove(self, name: str) -> None:
        if not safe_lookup_name(name):
            raise InvalidName(f"invalid machine name {name!r}")
        def drop_slot(entry: dict) -> None:
            slot_id = entry.get("slot_id")
            if slot_id:
                shutil.rmtree(self.queue_dir / slot_id, ignore_errors=True)

        try:
            outcome = queue_store.remove(self.queue_dir, name, on_removed=drop_slot)
        except json.JSONDecodeError as e:
            raise QueueUnreadable(f"queue.json is not valid JSON: {e}")
        if outcome == "not-found":
            raise NotFound(f"{name} is not in the queue")
        if outcome == "assigned":
            raise Conflict(f"{name} is already assigned")
