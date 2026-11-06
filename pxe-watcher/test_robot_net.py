#!/usr/bin/env python3
"""Tests for scripts/lib/robot-net.sh, which build-config.sh uses to refuse a
robot-network setting before it reaches the installer config."""

import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "robot-net.sh"


def accepted(function: str, value: str) -> bool:
    script = f'source "{LIB}"; {function} "$1"'
    result = subprocess.run(["bash", "-c", script, "bash", value], env={"PATH": os.environ["PATH"]},
                            capture_output=True, text=True, timeout=30)
    return result.returncode == 0


class RobotNetAddressTest(unittest.TestCase):
    def test_private_addresses_with_any_prefix_and_none_are_accepted(self):
        for value in ("192.168.20.1/24", "10.0.0.1/8", "10.255.255.254/30", "172.16.0.1/12", "172.31.9.9/16",
                      "192.168.0.1/32", "10.1.2.3/0", "none"):
            with self.subTest(value):
                self.assertTrue(accepted("valid_robot_net_address", value))

    def test_public_malformed_or_prefixless_addresses_are_refused(self):
        for value in ("8.8.8.8/24", "172.15.0.1/16", "172.32.0.1/16", "192.169.0.1/24", "11.0.0.1/8",
                      "192.168.20.1", "192.168.20.1/33", "192.168.256.1/24", "192.168.020.1/24", "192.168.20/24",
                      "", "None", "192.168.20.1/24 ", "192.168.20.1/24;reboot"):
            with self.subTest(repr(value)):
                self.assertFalse(accepted("valid_robot_net_address", value))


class RobotNetPortTest(unittest.TestCase):
    def test_interface_names_and_blank_are_accepted(self):
        for value in ("", "enp3s0", "eno1", "enx00e04c680001", "eth0.20", "br_lan-1"):
            with self.subTest(repr(value)):
                self.assertTrue(accepted("valid_robot_net_port", value))

    def test_names_linux_could_not_hold_or_that_carry_shell_are_refused(self):
        for value in ("enp3s0x123456789", "en p3", "enp3s0;reboot", "$(id)", "enp3/0", "en\"p"):
            with self.subTest(repr(value)):
                self.assertFalse(accepted("valid_robot_net_port", value))


if __name__ == "__main__":
    unittest.main()
