# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]


class ScanFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "workspace"
        self.root.mkdir()
        self.init_repo(self.root)
        self.installation = Path(self.temp.name) / "installation"
        script_dir = self.installation / "scripts/scripts"
        script_dir.mkdir(parents=True)
        for name in ["quality-scan.py", "quality_scan_patterns.py", "quality_scan_complexity.py"]:
            shutil.copyfile(SOURCE / name, script_dir / name)
        self.scanner = script_dir / "quality-scan.py"
        self.helper = self.installation / "scripts/tools/architecture-check/target/debug/vauchi-quality-complexity"

    def git(self, repo, *args):
        return subprocess.check_output(
            ["git", "-C", str(repo), *args], text=True, stderr=subprocess.PIPE
        ).strip()

    def init_repo(self, path):
        path.mkdir(exist_ok=True)
        self.git(path, "init", "-q")
        self.git(path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        return path

    def tracked(self, repo, relative, source):
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        self.git(repo, "add", "--", relative)
        return path

    def run_scan(self, *args):
        return subprocess.run(
            [sys.executable, str(self.scanner), "--workspace", str(self.root), *args],
            capture_output=True, text=True, check=False,
            env={**os.environ, **getattr(self, "extra_env", {})},
        )

    def report(self, *args):
        result = self.run_scan(*args, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def complexity_helper(self, response, exit_code=0):
        self.helper.parent.mkdir(parents=True, exist_ok=True)
        self.capture = Path(self.temp.name) / "request.json"
        failed = {f["path"] for f in response.get("failures", [])}
        paths = [p.relative_to(self.root).as_posix() for p in sorted(self.root.rglob("*.rs"))
                 if p.relative_to(self.root).as_posix() not in failed]
        response = {"formula_version": 1,
                    "analyzed_paths": paths[:response.get("files_analyzed", 0)], **response}
        self.helper.write_text(
            "#!/usr/bin/env python3\nimport json, pathlib, sys\n"
            f"pathlib.Path({str(self.capture)!r}).write_text(sys.stdin.read())\n"
            f"print({json.dumps(response)!r})\nsys.exit({exit_code})\n"
        )
        self.helper.chmod(0o755)
