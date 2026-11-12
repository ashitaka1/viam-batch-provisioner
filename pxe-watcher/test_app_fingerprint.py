#!/usr/bin/env python3
"""Tests for scripts/lib/app-fingerprint.sh, which decides whether `just app` rebuilds the bundle."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "app-fingerprint.sh"


class AppFingerprintTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for path, text in {
            "Package.swift": "// package",
            "Package.resolved": "{}",
            "Sources/App/main.swift": "print(1)",
            "App/Info.plist": "<plist/>",
            "App/LaunchDaemons/netboot.plist": "<plist/>",
            "openapi/provisioner.yaml": "openapi: 3.1.0",
            "scripts/bundle-app.sh": "#!/bin/bash",
        }.items():
            self.write(path, text)
        os.symlink("../../openapi/provisioner.yaml", self.root / "Sources/App/openapi.yaml")

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def fingerprint(self, *settings):
        script = f'set -euo pipefail; source "{LIB}"; app_fingerprint "$@"'
        result = subprocess.run(["bash", "-c", script, "bash", str(self.root), *settings],
                                capture_output=True, text=True, timeout=30, check=True)
        return result.stdout.strip()

    def test_unchanged_inputs_give_the_same_fingerprint(self):
        self.assertEqual(self.fingerprint("Developer ID", "cert1"), self.fingerprint("Developer ID", "cert1"))

    def test_each_input_changes_the_fingerprint(self):
        edits = {
            "edited source": lambda: self.write("Sources/App/main.swift", "print(2)"),
            "new source": lambda: self.write("Sources/App/extra.swift", ""),
            "renamed source": lambda: (self.root / "Sources/App/main.swift").rename(self.root / "Sources/App/Main.swift"),
            "Package.swift": lambda: self.write("Package.swift", "// changed"),
            "Package.resolved": lambda: self.write("Package.resolved", '{"pins": []}'),
            "removed Package.resolved": lambda: (self.root / "Package.resolved").unlink(),
            "Info.plist": lambda: self.write("App/Info.plist", "<plist></plist>"),
            "launch daemon plist": lambda: self.write("App/LaunchDaemons/netboot.plist", "<plist></plist>"),
            "OpenAPI spec": lambda: self.write("openapi/provisioner.yaml", "openapi: 3.1.1"),
            "bundle script": lambda: self.write("scripts/bundle-app.sh", "#!/bin/bash\n"),
        }
        for name, edit in edits.items():
            with self.subTest(name):
                before = self.fingerprint()
                edit()
                self.assertNotEqual(self.fingerprint(), before, f"{name} left the fingerprint unchanged")

    def test_each_setting_changes_the_fingerprint(self):
        cases = {
            "identity": (("Developer ID A", "cert1", "swift 6.4"), ("Developer ID B", "cert1", "swift 6.4")),
            "ad hoc": (("", "", "swift 6.4"), ("Developer ID A", "cert1", "swift 6.4")),
            "renewed certificate": (("Developer ID A", "cert1", "swift 6.4"), ("Developer ID A", "cert2", "swift 6.4")),
            "toolchain": (("Developer ID A", "cert1", "swift 6.4"), ("Developer ID A", "cert1", "swift 6.5")),
            "setting boundary": (("ab", "c"), ("a", "bc")),
        }
        for name, (first, second) in cases.items():
            with self.subTest(name):
                self.assertNotEqual(self.fingerprint(*first), self.fingerprint(*second),
                                    f"{name} left the fingerprint unchanged")

    def test_a_missing_root_fails(self):
        script = f'set -euo pipefail; source "{LIB}"; app_fingerprint /nonexistent'
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)

    def test_hidden_and_backup_files_leave_the_fingerprint_alone(self):
        for junk in ("Sources/App/.DS_Store", "Sources/App/.main.swift.swp", "Sources/App/main.swift~",
                     "Sources/App/main.swift.orig"):
            with self.subTest(junk):
                before = self.fingerprint()
                self.write(junk, "junk")
                self.assertEqual(self.fingerprint(), before, f"{junk} changed the fingerprint")


if __name__ == "__main__":
    unittest.main()
