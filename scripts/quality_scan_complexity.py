# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Invoke the existing Syn-based analyzer without compiling application crates."""

import json
import os
import subprocess
from pathlib import Path


def measure(sources):
    target = Path(__file__).resolve().parents[1] / "tools/architecture-check/target"
    binary = (
        target / "debug" / ("vauchi-quality-complexity.exe" if os.name == "nt"
                            else "vauchi-quality-complexity")
    )
    if sources:
        if (not binary.is_file() or binary.is_symlink()
                or any(parent.is_symlink() for parent in binary.parents)):
            raise ValueError("Complexity helper unavailable or symlinked; run just quality-complexity-build")
        result = subprocess.run(
            [str(binary)], input=json.dumps(sources), capture_output=True, text=True,
            encoding="utf-8",
            timeout=120, check=False,
        )
        if result.returncode not in (0, 2):
            raise ValueError(f"Complexity helper failed: {result.stderr.strip()}")
        data = json.loads(result.stdout)
        if not isinstance(data, dict) or type(data.get("formula_version")) is not int or data["formula_version"] != 1:
            raise ValueError("Invalid complexity coverage report")
        analyzed, failures = data.get("files_analyzed"), data.get("failures")
        if (type(analyzed) is not int or analyzed < 0 or not isinstance(failures, list)
                or not isinstance(data.get("functions"), list)
                or not isinstance(data.get("analyzed_paths"), list)
                or analyzed + len(failures) != len(sources)
                or bool(failures) != (result.returncode == 2)):
            raise ValueError("Incomplete or inconsistent complexity coverage report")
        expected = {source["path"] for source in sources}
        paths = data["analyzed_paths"]
        if (any(not isinstance(path, str) for path in paths)
                or any(not isinstance(failure, dict) or not isinstance(failure.get("path"), str)
                       or not isinstance(failure.get("error"), str) for failure in failures)):
            raise ValueError("Invalid complexity coverage paths")
        failed = [failure["path"] for failure in failures]
        if (len(paths) != analyzed or len(set(paths)) != len(paths)
                or len(set(failed)) != len(failed) or set(paths) & set(failed)
                or set(paths) | set(failed) != expected):
            raise ValueError("Complexity coverage does not match requested files")
        fields = {"line": 1, "column": 1, "cyclomatic": 1, "max_nesting": 0, "macro_invocations": 0}
        for function in data["functions"]:
            if (not isinstance(function, dict) or function.get("path") not in paths
                    or not isinstance(function.get("name"), str) or not function["name"]
                    or any(type(function.get(key)) is not int or function[key] < minimum
                           for key, minimum in fields.items())):
                raise ValueError("Invalid complexity function record")
    else:
        data = {"formula_version": 1, "files_analyzed": 0, "analyzed_paths": [],
                "failures": [], "functions": [], "macro_invocations": 0}
    return {
        **data, "files_requested": len(sources), "metric": "syntactic-cyclomatic",
        "parser": "syn 2, unexpanded Rust AST",
        "limitations": "Rust only; macros not expanded; no cognitive-complexity claim",
    }
