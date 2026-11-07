# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Invoke the existing Syn-based analyzer without compiling application crates."""

import json
import os
import subprocess
from pathlib import Path


def measure(workspace, sources):
    target = Path(os.environ.get(
        "CARGO_TARGET_DIR", workspace / "scripts/tools/architecture-check/target"
    ))
    binary = os.environ.get("VAUCHI_COMPLEXITY_BIN", str(
        target / "debug" / ("vauchi-quality-complexity.exe" if os.name == "nt"
                            else "vauchi-quality-complexity")
    ))
    if sources:
        result = subprocess.run(
            [binary], input=json.dumps(sources), capture_output=True, text=True,
            timeout=120, check=False,
        )
        if result.returncode not in (0, 2):
            raise ValueError(f"Complexity helper failed: {result.stderr.strip()}")
        data = json.loads(result.stdout)
        if not isinstance(data, dict):
            raise ValueError("Invalid complexity coverage report")
        analyzed, failures = data.get("files_analyzed"), data.get("failures")
        if (not isinstance(analyzed, int) or analyzed < 0 or not isinstance(failures, list)
                or not isinstance(data.get("functions"), list)
                or analyzed + len(failures) != len(sources)
                or bool(failures) != (result.returncode == 2)):
            raise ValueError("Incomplete or inconsistent complexity coverage report")
    else:
        data = {"files_analyzed": 0, "failures": [], "functions": [], "macro_invocations": 0}
    return {
        **data, "files_requested": len(sources), "metric": "syntactic-cyclomatic",
        "parser": "syn 2, unexpanded Rust AST",
        "limitations": "Rust only; macros not expanded; no cognitive-complexity claim",
    }
