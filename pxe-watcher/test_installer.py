#!/usr/bin/env python3
"""Tests for the installer side of failure detection: the report script the
installer runs, and the autoinstall config that is generated for it.

The script runs inside the Ubuntu installer and talks to the server over
HTTP. Here it runs under /bin/sh with a stub curl that records what it was
asked to send.
"""

import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "http-server" / "scripts" / "install-report.sh"
TEMPLATE = REPO / "templates" / "user-data.tpl"
BUILD_CONFIG = REPO / "scripts" / "build-config.sh"

try:
    import yaml
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False

STUB_CURL = """#!/bin/sh
# Records the JSON body of each call. Fails every call when STUB_EXIT is set,
# and any call whose body contains STUB_FAIL_FOR.
body=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-d" ]; then body="$2"; shift; fi
    shift
done
printf '%s\\n' "$body" >> "$STUB_DIR/bodies"
if [ -n "$STUB_EXIT" ]; then exit "$STUB_EXIT"; fi
if [ -n "$STUB_FAIL_FOR" ]; then
    case "$body" in *"$STUB_FAIL_FOR"*) exit 22 ;; esac
fi
exit 0
"""

SAFE_REASON = re.compile(r"[A-Za-z0-9 ._:/=,()-]*")


class InstallReportScriptTest(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.state = self.tmp / "state"
        self.net = self.tmp / "net"
        for d in (self.bin, self.state, self.net):
            d.mkdir()
        stub = self.bin / "curl"
        stub.write_text(STUB_CURL)
        stub.chmod(0o755)
        self.cmdline = self.tmp / "cmdline"
        self.cmdline.write_text("BOOT_IMAGE=/vmlinuz ip=dhcp autoinstall ---\n")

    def tearDown(self):
        self._tmp.cleanup()

    def nic(self, name, address):
        (self.net / name).mkdir()
        (self.net / name / "address").write_text(address + "\n")

    def run_script(self, *args, path=None, **env):
        environment = {
            "PATH": path if path is not None else f"{self.bin}:{os.environ['PATH']}",
            "STUB_DIR": str(self.tmp),
            "REPORT_STATE_DIR": str(self.state),
            "REPORT_CMDLINE": str(self.cmdline),
            "REPORT_SYS_NET": str(self.net),
        }
        environment.update(env)
        return subprocess.run(["/bin/sh", str(SCRIPT), "10.1.0.5:8234", *args],
                              env=environment, capture_output=True, text=True, timeout=30)

    def bodies(self):
        path = self.tmp / "bodies"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_the_report_script_sends_valid_reports_for_the_right_machine_and_always_exits_0(self):
        with self.subTest("a hostile reason still yields valid JSON and runs nothing"):
            self.cmdline.write_text("ip=dhcp viam_hostname=lab-7 ---\n")
            pwned = self.tmp / "pwned"
            reason = f'say "hi" \\ back\nslash $(touch {pwned}) `touch {pwned}`; \'quoted\''
            result = self.run_script("failed", "tooling", reason)
            (body,) = self.bodies()
            self.assertFalse(pwned.exists())
            self.assertEqual((body["kind"], body["stage"], body["name"]), ("failed", "tooling", "lab-7"))
            self.assertIn("hi", body["reason"])
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("nothing outside the safe character set reaches the body, and the length is capped"):
            result = self.run_script("failed", "tooling", "x" * 1000 + "\té☃ " + "y" * 50)
            (body,) = self.bodies()
            self.assertRegex(body["reason"], SAFE_REASON)
            self.assertLessEqual(len(body["reason"]), 400)
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("a name on the kernel command line is reported once, by name"):
            result = self.run_script("progress", "identity")
            (body,) = self.bodies()
            self.assertEqual((body["name"], body["kind"], body["stage"]), ("lab-7", "progress", "identity"))
            self.assertNotIn("mac", body)
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("without a name, each ethernet NIC is tried until one is accepted"):
            self.cmdline.write_text("ip=dhcp autoinstall ---\n")
            self.nic("lo", "00:00:00:00:00:00")
            self.nic("eno1", "AA:BB:CC:DD:EE:01")
            self.nic("enp2s0", "aa:bb:cc:dd:ee:02")
            self.nic("wlan0", "aa:bb:cc:dd:ee:03")
            result = self.run_script("progress", "identity", STUB_FAIL_FOR="aa:bb:cc:dd:ee:01")
            macs = [b["mac"] for b in self.bodies()]
            self.assertEqual(sorted(macs), ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"])
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("the first accepted NIC ends the search"):
            result = self.run_script("progress", "identity")
            self.assertEqual(len(self.bodies()), 1)
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("a failing curl does not fail the script"):
            result = self.run_script("failed", "tooling", "boom", STUB_EXIT="7")
            self.assertGreaterEqual(len(self.bodies()), 1)
            self.assertEqual(result.returncode, 0)

        with self.subTest("a missing curl does not fail the script"):
            tools = self.tmp / "tools"
            tools.mkdir()
            for tool in ("tr", "sed", "cut", "head", "cat"):
                (tools / tool).symlink_to(shutil.which(tool))
            result = self.run_script("progress", "identity", path=str(tools))
            self.assertEqual(result.returncode, 0)

    def test_the_stage_survives_a_failed_report_and_fills_in_auto(self):
        self.cmdline.write_text("ip=dhcp viam_hostname=lab-7 ---\n")

        with self.subTest("no stage recorded yet means the installer had not reached late-commands"):
            self.run_script("failed", "auto", "boom")
            self.assertEqual(self.bodies()[-1]["stage"], "installer")

        with self.subTest("the last progress stage is remembered even when its report could not be sent"):
            self.run_script("progress", "tooling", STUB_EXIT="7")
            self.assertEqual((self.state / "viam-install-stage").read_text().strip(), "tooling")
            self.run_script("failed", "auto", "boom")
            self.assertEqual(self.bodies()[-1]["stage"], "tooling")


def build_config_parts():
    """The envsubst whitelist and the variables build-config.sh exports."""
    script = BUILD_CONFIG.read_text()
    whitelist = re.search(r"envsubst '([^']*)'", script).group(1)
    names = [n for n in re.findall(r"\$\{(\w+)\}", whitelist)]
    exported = set()
    for match in re.finditer(r"^export\s+(.+)$", script, re.MULTILINE):
        for token in match.group(1).split():
            exported.add(token.split("=")[0])
    return whitelist, names, exported


@unittest.skipUnless(HAVE_YAML and shutil.which("envsubst"), "PyYAML and envsubst required")
class RenderedUserDataTest(unittest.TestCase):
    def test_the_generated_installer_config_is_valid(self):
        whitelist, names, exported = build_config_parts()
        values = {name: f"dummy-{name.lower()}" for name in names}
        values["PACKAGES"] = "    - curl\n    - jq"
        env = dict(os.environ)
        env.update(values)

        rendered = subprocess.run(
            ["envsubst", whitelist], input=TEMPLATE.read_text(), env=env,
            capture_output=True, text=True, check=True).stdout

        parsed = yaml.safe_load(rendered)
        self.assertIsInstance(parsed.get("autoinstall"), dict, "rendered config is not an autoinstall document")
        self.assertEqual(set(names), exported, "build-config.sh exports and substitutes different variables")
        for name in exported:
            self.assertNotIn("${" + name + "}", rendered, f"${{{name}}} was left unsubstituted")


if __name__ == "__main__":
    unittest.main()
