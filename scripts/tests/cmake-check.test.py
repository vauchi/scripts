# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Inject native tool failures into the production CMake gate."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CmakeGateTests(unittest.TestCase):
    # @internal — a timing wrapper must preserve failure and skip statuses
    def test_pre_push_timing_wrapper_preserves_conditional_exit_status(self):
        hook = (ROOT / "hooks/pre-push").read_text(encoding="utf-8")
        wrapper = re.search(r"    time_step\(\) \{.*?\n    \}", hook, re.S)
        self.assertIsNotNone(wrapper)
        for status in (0, 17, 77):
            script = ("set -eu\nSTEP_NAMES=()\nSTEP_TIMES=()\n" + wrapper.group(0)
                      + f"\nresult=0\ntime_step sentinel bash -c 'exit {status}' || result=$?\nexit $result")
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)

    # @internal — build orchestration at the external tool boundary
    def test_configure_build_and_test_failures_stop_the_gate(self):
        for failing in ("configure", "build", "test", ""):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source with spaces"
                source.mkdir()
                (source / "CMakeLists.txt").touch()
                binary = root / "bin"
                binary.mkdir()
                for name in ("cmake", "ctest", "sccache"):
                    tool = binary / name
                    tool.write_text('''#!/bin/sh
case "$(basename "$0"):$1" in
    cmake:-S) phase=configure ;;
    cmake:--build) phase=build ;;
    ctest:*) phase=test ;;
    *) exit 0 ;;
esac
printf '%s %s\\n' "$phase" "$*" >> "$CALL_LOG"
[ "$phase" != "$FAIL_PHASE" ]
''', encoding="utf-8")
                    tool.chmod(0o755)
                log = root / "calls"
                environment = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                                   CALL_LOG=str(log), FAIL_PHASE=failing)
                result = subprocess.run(["bash", str(ROOT / "scripts/cmake-check.sh"), str(source)],
                                        env=environment, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, not failing, result.stderr)
                calls = log.read_text(encoding="utf-8").splitlines()
                phases = [line.split()[0] for line in calls]
                expected = ["configure", "build", "test"]
                if failing:
                    expected = expected[:expected.index(failing) + 1]
                self.assertEqual(phases, expected)
                self.assertIn("CMAKE_CXX_COMPILER_LAUNCHER=sccache", calls[0])
                if not failing:
                    self.assertIn("--no-tests=error", calls[-1])

    # @internal — unknown build systems must not receive a passing stamp
    def test_pre_push_unknown_project_fails(self):
        hook = (ROOT / "hooks/pre-push").read_text(encoding="utf-8")
        unknown = re.search(r"# ─── Unknown repo type[^\n]*\n\s*\n\s*else\n(.*?)\n    fi", hook, re.S)
        self.assertIsNotNone(unknown)
        result = subprocess.run(["bash", "-c", unknown.group(1)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
