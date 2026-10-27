# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Inject cargo failures into the production WASM crate gate."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts/wasm-check.sh"

FAKE_CARGO = '''#!/bin/sh
printf '%s %s\\n' "$1" "$PWD" >> "$CALL_LOG"
[ "$1" != "$FAIL_PHASE" ]
'''


def run_gate(root, repo, failing=""):
    binary = root / "bin"
    binary.mkdir(exist_ok=True)
    cargo = binary / "cargo"
    cargo.write_text(FAKE_CARGO)
    cargo.chmod(0o755)
    log = root / "calls"
    environment = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                       CALL_LOG=str(log), FAIL_PHASE=failing)
    result = subprocess.run(["bash", str(GATE), str(repo)], env=environment,
                            text=True, capture_output=True, timeout=10)
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


class WasmGateTests(unittest.TestCase):
    # @internal — each cargo step at the external tool boundary stops the gate
    def test_format_lint_and_test_failures_stop_the_gate(self):
        expected = ["fmt", "clippy", "test"]
        for failing in ("fmt", "clippy", "test", ""):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo = root / "web demo"
                (repo / "wasm").mkdir(parents=True)
                (repo / "wasm/Cargo.toml").touch()

                result, calls = run_gate(root, repo, failing)

                self.assertEqual(result.returncode == 0, not failing, result.stderr)
                phases = [line.split()[0] for line in calls]
                ran = expected[:expected.index(failing) + 1] if failing else expected
                self.assertEqual(phases, ran)
                crate = (repo / "wasm").resolve()
                directories = {Path(line.split(" ", 1)[1]).resolve() for line in calls}
                self.assertEqual(directories, {crate})

    # @internal — a repo without the crate fails instead of passing vacuously
    def test_a_repo_without_the_wasm_crate_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()

            result, calls = run_gate(root, repo)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("wasm/Cargo.toml", result.stderr)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
