#!/usr/bin/env python3
"""Tests for scripts/lib/site-env.sh, the settings reader every script sources.

A bad setting must make `source site-env.sh` fail, because the scripts treat
that as their signal to stop.
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "site-env.sh"


def source_site_env(**settings):
    """(exit status of `source`, "API HTTP TIMEOUT" values) with no site.env file."""
    env = {"PATH": os.environ["PATH"], "SITE_CONFIG": "/nonexistent/site.env"}
    env.update(settings)
    script = f'REPO_ROOT="{REPO}"; source "{LIB}"; rc=$?; echo "$rc $API_PORT $HTTP_PORT $INSTALL_TIMEOUT_MINUTES"'
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=30).stdout
    rc, *values = out.split()
    return int(rc), values


class SiteEnvTest(unittest.TestCase):
    def test_defaults_when_nothing_is_set(self):
        self.assertEqual(source_site_env(), (0, ["8235", "8234", "45"]))

    def test_environment_overrides_the_defaults_and_zero_turns_the_timeout_off(self):
        self.assertEqual(source_site_env(API_PORT="9000", HTTP_PORT="9001", INSTALL_TIMEOUT_MINUTES="0"),
                         (0, ["9000", "9001", "0"]))

    def test_a_setting_that_is_not_a_number_fails_the_source(self):
        for name, value in (("API_PORT", "abc"), ("HTTP_PORT", "80x"), ("INSTALL_TIMEOUT_MINUTES", "-5"),
                            ("INSTALL_TIMEOUT_MINUTES", "soon")):
            with self.subTest(f"{name}={value}"):
                status, _ = source_site_env(**{name: value})
                self.assertNotEqual(status, 0, f"{name}={value} was accepted")


if __name__ == "__main__":
    unittest.main()
