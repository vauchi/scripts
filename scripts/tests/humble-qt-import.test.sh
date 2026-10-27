#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel: a retired Qt domain import must fail even behind an exception.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR/.." <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source = root / "linux-qt/src/import.cpp"
    source.parent.mkdir(parents=True)
    command = [
        sys.executable, str(scripts / "humble_check.py"),
        "--repo", "linux-qt", "--workspace-root", str(root),
        "--config", str(scripts / "humble_check_rules.json"),
        "--check", str(scripts / "humble_check.baseline.json"),
    ]
    for marker in ("", "// TODO(HUMBLE): temporary", "// HUMBLE-EXCEPTION: legacy"):
        source.write_text(marker + "\nvauchi_app_import_contacts_from_vcf(app, bytes);\n")
        result = subprocess.run(command, text=True, capture_output=True)
        assert result.returncode == 1, (marker, result.returncode, result.stdout, result.stderr)
        report = json.loads(subprocess.check_output(command[:-2], text=True))
        assert report["totals"]["retired_qt_domain_import"] == 1, report

    source.write_text('dispatchEvent({{"FilePickCompleted", payload}});\n')
    result = subprocess.run(command, text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    report = json.loads(subprocess.check_output(command[:-2], text=True))
    assert report["totals"]["retired_qt_domain_import"] == 0
print("Qt import retirement: 3 injected violations rejected; generic event accepted")
PY
