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
# Stands in for curl: records each call's JSON body and prints the HTTP status
# curl would print for -w '%{http_code}'.
#   STUB_EXIT        the connection fails: print 000 and exit with this code
#   STUB_FAIL_FIRST  answer 502 to the first N calls
#   STUB_FAIL_FOR    answer 404 to calls whose body contains this text
body=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-d" ]; then body="$2"; shift; fi
    shift
done
printf '%s\\n' "$body" >> "$STUB_DIR/bodies"
if [ -n "$STUB_EXIT" ]; then printf 000; exit "$STUB_EXIT"; fi
if [ -n "$STUB_FAIL_FIRST" ]; then
    calls=$(wc -l < "$STUB_DIR/bodies" | tr -d ' ')
    if [ "$calls" -le "$STUB_FAIL_FIRST" ]; then printf 502; exit 0; fi
fi
if [ -n "$STUB_FAIL_FOR" ]; then
    case "$body" in *"$STUB_FAIL_FOR"*) printf 404; exit 0 ;; esac
fi
printf 200
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
            "REPORT_RETRY_DELAY": "0",
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
            self.assertIsNotNone(SAFE_REASON.fullmatch(body["reason"]), f"unsafe characters in {body['reason']!r}")
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("nothing outside the safe character set reaches the body, and the length is capped"):
            result = self.run_script("failed", "tooling", "x" * 1000 + "\té☃ " + "y" * 50)
            (body,) = self.bodies()
            self.assertIsNotNone(SAFE_REASON.fullmatch(body["reason"]), f"unsafe characters in {body['reason']!r}")
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

    def test_a_name_with_uppercase_dots_or_underscores_is_reported_as_it_is(self):
        self.cmdline.write_text("ip=dhcp viam_hostname=Lab_7.x ---\n")
        self.run_script("progress", "identity")
        (body,) = self.bodies()
        self.assertEqual(body["name"], "Lab_7.x")

    def test_the_final_reports_survive_a_briefly_unavailable_server_but_a_refusal_is_final(self):
        self.cmdline.write_text("ip=dhcp viam_hostname=lab-7 ---\n")

        with self.subTest("done is retried until the server answers, so a good install is not timed out"):
            result = self.run_script("progress", "done", STUB_FAIL_FIRST="2")
            self.assertEqual(len(self.bodies()), 3)
            self.assertEqual(result.returncode, 0)

        (self.tmp / "bodies").unlink()
        with self.subTest("a failure report is retried too"):
            self.run_script("failed", "tooling", "boom", STUB_FAIL_FIRST="1")
            self.assertEqual(len(self.bodies()), 2)

        (self.tmp / "bodies").unlink()
        with self.subTest("an ordinary progress report is sent once"):
            self.run_script("progress", "tooling", STUB_FAIL_FIRST="1")
            self.assertEqual(len(self.bodies()), 1)

        (self.tmp / "bodies").unlink()
        with self.subTest("a refusal from the server is not retried"):
            self.run_script("failed", "tooling", "boom", STUB_FAIL_FOR="lab-7")
            self.assertEqual(len(self.bodies()), 1)

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

    def test_done_carries_the_warning_the_late_commands_left_and_nothing_else_does(self):
        self.cmdline.write_text("ip=dhcp viam_hostname=lab-7 ---\n")
        (self.state / "viam-install-warning").write_text(
            "Cabled on the robot-network port enp3s0: move the cable to another port.\n")

        with self.subTest("the done report carries it"):
            self.run_script("progress", "done")
            self.assertEqual(self.bodies()[-1]["warning"],
                             "Cabled on the robot-network port enp3s0: move the cable to another port.")

        with self.subTest("other progress and failures don't"):
            self.run_script("progress", "tooling")
            self.run_script("failed", "tooling", "boom")
            self.assertNotIn("warning", self.bodies()[-2])
            self.assertNotIn("warning", self.bodies()[-1])

        with self.subTest("a hostile warning still yields valid JSON"):
            (self.state / "viam-install-warning").write_text('port "x" \\ $(id)\n')
            self.run_script("progress", "done")
            self.assertIsNotNone(SAFE_REASON.fullmatch(self.bodies()[-1]["warning"]))

        (self.state / "viam-install-warning").unlink()
        with self.subTest("without one, done has no warning"):
            self.run_script("progress", "done")
            self.assertNotIn("warning", self.bodies()[-1])


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


# Stands in for iproute2 on the target: `ip -o -4 addr show` lists the cabled
# port, `ip -o link show` every port in STUB_LINKS.
STUB_IP = """#!/bin/sh
case "$*" in
    *addr*)
        echo "1: lo    inet 127.0.0.1/8 scope host lo"
        [ -n "$STUB_UPLINK" ] && echo "2: $STUB_UPLINK    inet 10.1.0.20/24 brd 10.1.0.255 scope global $STUB_UPLINK"
        ;;
    *link*)
        echo "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN"
        n=2
        for link in $STUB_LINKS; do
            echo "$n: $link: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP"
            n=$((n + 1))
        done
        ;;
esac
"""

# Stands in for curl in the installer: a download (-o) gets the real report
# script, and a report's JSON body is recorded and answered 200.
STUB_INSTALLER_CURL = """#!/bin/sh
out=""
body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -d) body="$2"; shift ;;
    esac
    shift
done
if [ -n "$out" ] && [ "$out" != /dev/null ]; then cp "$REPORT_SCRIPT" "$out"; exit 0; fi
printf '%s\\n' "$body" >> "$STUB_DIR/bodies"
printf 200
"""

ROBOT_WARNING = "Cabled on the robot-network port enp3s0: move the cable to another port."

# The netplan config the network late-command wrote before ROBOT_NET_ADDRESS
# and ROBOT_NET_PORT existed, for a machine cabled on enp2s0.
NETPLAN_BEFORE = """network:
  version: 2
  ethernets:
    enp2s0:
      dhcp4: true
      dhcp6: true
    enp3s0:
      addresses:
        - 192.168.20.1/24
      dhcp4: false
      optional: true
"""


@unittest.skipUnless(HAVE_YAML and shutil.which("envsubst"), "PyYAML and envsubst required")
class RobotNetworkTest(unittest.TestCase):
    """build-config.sh renders the robot-network settings, and the installer
    commands they reach run here under /bin/sh with the installer's paths
    (/target, /tmp, /sys/class/net) moved into a scratch directory."""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.root = self.tmp / "root"
        self.bin = self.tmp / "bin"
        for d in (self.repo / "scripts" / "lib", self.repo / "templates", self.repo / "config" / "environments",
                  self.repo / "http-server" / "autoinstall", self.root / "target" / "etc" / "netplan",
                  self.root / "target" / "var" / "log", self.root / "tmp", self.root / "sys" / "class" / "net",
                  self.bin):
            d.mkdir(parents=True)
        shutil.copy(BUILD_CONFIG, self.repo / "scripts")
        shutil.copy(REPO / "scripts" / "lib" / "robot-net.sh", self.repo / "scripts" / "lib")
        shutil.copy(TEMPLATE, self.repo / "templates")
        hasher = self.repo / "scripts" / "hash-password.sh"
        hasher.write_text("#!/bin/sh\necho '$6$stub$hash'\n")
        hasher.chmod(0o755)
        (self.tmp / "key.pub").write_text("ssh-ed25519 AAAA test\n")
        (self.repo / "config" / "environments" / "t.packages.txt").write_text("curl\n")
        for name, text in (("ip", STUB_IP), ("curl", STUB_INSTALLER_CURL)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)

    def tearDown(self):
        self._tmp.cleanup()

    def build(self, **settings):
        """Run build-config.sh on an environment file holding these settings."""
        lines = ["PASSWORD=pw", f"SSH_PUBLIC_KEY_FILE={self.tmp / 'key.pub'}", "PXE_SERVER=10.1.0.5:8234"]
        lines += [f"{key}={value}" for key, value in settings.items()]
        (self.repo / "config" / "environments" / "t.env").write_text("\n".join(lines) + "\n")
        site = self.repo / "config" / "site.env"
        if not site.is_symlink():
            site.symlink_to("environments/t.env")
        return subprocess.run(["bash", str(self.repo / "scripts" / "build-config.sh")],
                              env={"PATH": os.environ["PATH"], "HOME": str(self.tmp)},
                              capture_output=True, text=True, timeout=30)

    def commands(self, **settings):
        result = self.build(**settings)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = yaml.safe_load((self.repo / "http-server" / "autoinstall" / "user-data").read_text())["autoinstall"]
        network = next(c for c in config["late-commands"] if "99-netplan.yaml" in c)
        return config["early-commands"][0], network, config["error-commands"][0]

    def run_command(self, command, *, uplink="enp2s0", links=("enp2s0", "enp3s0", "enp4s0", "enp5s0")):
        for old in ("/target", "/tmp/", "/sys/class/net/", "/var/crash/"):
            command = command.replace(old, f"{self.root}{old}")
        for link in links:
            (self.root / "sys" / "class" / "net" / link).mkdir(exist_ok=True)
        env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}", "STUB_DIR": str(self.tmp), "STUB_UPLINK": uplink,
            "STUB_LINKS": " ".join(links), "REPORT_SCRIPT": str(SCRIPT), "REPORT_STATE_DIR": str(self.root / "tmp"),
            "REPORT_CMDLINE": str(self.tmp / "cmdline"), "REPORT_RETRY_DELAY": "0",
        }
        (self.tmp / "cmdline").write_text("ip=dhcp viam_hostname=lab-7 ---\n")
        return subprocess.run(["/bin/sh", "-c", command], env=env, capture_output=True, text=True, timeout=30)

    def netplan(self):
        return (self.root / "target" / "etc" / "netplan" / "99-netplan.yaml").read_text()

    def warning_file(self):
        return self.root / "tmp" / "viam-install-warning"

    def bodies(self):
        path = self.tmp / "bodies"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_without_either_setting_the_network_is_configured_as_before(self):
        early, network, _ = self.commands()
        self.assertEqual(self.run_command(early).returncode, 0)
        self.assertEqual(self.run_command(network).returncode, 0)
        self.assertEqual(self.netplan(), NETPLAN_BEFORE)
        self.assertFalse(self.warning_file().exists())

    def test_an_address_without_a_port_goes_to_the_first_other_enp_port(self):
        _, network, _ = self.commands(ROBOT_NET_ADDRESS="10.20.0.1/16")
        self.run_command(network, uplink="enp3s0")
        ethernets = yaml.safe_load(self.netplan())["network"]["ethernets"]
        self.assertEqual(ethernets, {
            "enp3s0": {"dhcp4": True, "dhcp6": True},
            "enp2s0": {"addresses": ["10.20.0.1/16"], "dhcp4": False, "optional": True},
        })

    def test_none_leaves_only_the_uplink_and_ignores_a_named_port(self):
        early, network, _ = self.commands(ROBOT_NET_ADDRESS="none", ROBOT_NET_PORT="enp9s0")
        self.assertEqual(self.run_command(early).returncode, 0)
        self.run_command(network)
        self.assertEqual(yaml.safe_load(self.netplan())["network"]["ethernets"],
                         {"enp2s0": {"dhcp4": True, "dhcp6": True}})

    def test_a_named_port_takes_the_address_and_every_other_wired_port_takes_dhcp(self):
        early, network, _ = self.commands(ROBOT_NET_PORT="enp3s0")
        self.assertEqual(self.run_command(early).returncode, 0)
        self.run_command(network, uplink="enp2s0", links=("enp2s0", "enp3s0", "enp4s0", "wlp0s20f3", "eth0"))
        ethernets = yaml.safe_load(self.netplan())["network"]["ethernets"]
        dhcp = {"dhcp4": True, "dhcp6": True, "optional": True}
        self.assertEqual(ethernets, {
            "enp2s0": dhcp,
            "enp3s0": {"addresses": ["192.168.20.1/24"], "dhcp4": False, "optional": True},
            "enp4s0": dhcp,
            "eth0": dhcp,
        })
        self.assertFalse(self.warning_file().exists())

    def test_cabled_on_the_named_port_the_install_goes_on_and_done_carries_the_warning(self):
        _, network, _ = self.commands(ROBOT_NET_PORT="enp3s0")
        result = self.run_command(network, uplink="enp3s0")
        self.assertEqual(result.returncode, 0)
        ethernets = yaml.safe_load(self.netplan())["network"]["ethernets"]
        self.assertEqual(ethernets["enp3s0"]["addresses"], ["192.168.20.1/24"])
        self.assertTrue(ethernets["enp2s0"]["dhcp4"])
        self.assertEqual(self.warning_file().read_text().strip(), ROBOT_WARNING)

        self.run_command(f"sh {SCRIPT} 10.1.0.5:8234 progress done")
        self.assertEqual(self.bodies()[-1]["warning"], ROBOT_WARNING)

    def test_a_named_port_the_machine_lacks_fails_the_install_early_with_its_reason(self):
        early, _, error = self.commands(ROBOT_NET_PORT="enp9s0")
        result = self.run_command(early)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.bodies()[-1], {"kind": "failed", "stage": "installer", "name": "lab-7",
                                             "reason": "No port enp9s0"})

        with self.subTest("error-commands report the same reason"):
            self.run_command(error)
            self.assertEqual(self.bodies()[-1]["reason"], "No port enp9s0")

    def test_without_an_early_failure_error_commands_report_the_generic_reason(self):
        _, _, error = self.commands()
        self.run_command(error)
        self.assertEqual(self.bodies()[-1]["reason"], "autoinstall failed")

    def test_build_config_refuses_a_public_address_or_a_bad_port_name(self):
        for settings in ({"ROBOT_NET_ADDRESS": "8.8.8.8/24"}, {"ROBOT_NET_ADDRESS": "192.168.20.1"},
                         {"ROBOT_NET_PORT": "enp3s0x123456789"}):
            with self.subTest(settings):
                (self.repo / "http-server" / "autoinstall" / "user-data").unlink(missing_ok=True)
                result = self.build(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(next(iter(settings)), result.stderr)
                self.assertFalse((self.repo / "http-server" / "autoinstall" / "user-data").exists())


if __name__ == "__main__":
    unittest.main()
