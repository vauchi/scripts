#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""Conformance-suite drift guard (vauchi/private#1265).

The QR scanner, camera-corpus and executor conformance suites are run
against two implementations each, with the suite text copy-pasted between
repos. Only adapter lines (crate paths, feature cfgs, the fixture path
expression) may differ; anything else is drift and fails here.

Local use:  python3 check-conformance-sync.py [--root /path/to/workspace]
CI use:     python3 check-conformance-sync.py --api
            (both files read at $CONFORMANCE_OWN_REF, so the vendored
            copy is compared with the canonical file in the same tree)

Exit 0 all pairs in sync, 1 a pair drifted, 2 a fetch/read error.
"""

import difflib
import os
import re
import sys
import urllib.request
from pathlib import Path

PAIRS = [
    (
        "qr-scanner-pipeline",
        ("core", "vauchi-core/tests/it/qr_scanner_pipeline_tests.rs"),
        ("linux-hw", "tests/qr_scanner_pipeline_tests.rs"),
    ),
    (
        "qr-camera-corpus",
        ("core", "vauchi-core/tests/it/qr_decode_camera_corpus_tests.rs"),
        ("linux-hw", "tests/qr_decode_camera_corpus_tests.rs"),
    ),
    (
        "executor-conformance",
        ("contract", "tests/executor_conformance.rs"),
        ("core", "vauchi-core/tests/platform_executor_contract_tests.rs"),
    ),
]

PROJECT_IDS = {"core": 77874344, "linux-hw": 88343317, "contract": 88365544}
PROJECT_PATHS = {"core": "core", "linux-hw": "linux-hw", "contract": "contract"}
ADAPTER = re.compile(
    r"^#!\[cfg\(feature|^\s*use vauchi_|CARGO_MANIFEST_DIR|qr-camera-corpus"
)


def normalize(text: str) -> str:
    out = []
    skip_close_paren = False
    for line in text.splitlines():
        if line.strip() == ")":
            if skip_close_paren:
                skip_close_paren = False
                continue
        if skip_close_paren:
            continue
        if ADAPTER.search(line):
            continue
        if "PathBuf::from(" in line:
            skip_close_paren = True
            continue
        if not line.strip():
            continue
        out.append(line)
    return "\n".join(out)


def fetch_api(project: str, path: str, ref: str) -> str:
    quoted = urllib.parse.quote(path, safe="")
    url = (
        f"{os.environ['CI_API_V4_URL']}/projects/{PROJECT_IDS[project]}"
        f"/repository/files/{quoted}/raw?ref={ref}"
    )
    request = urllib.request.Request(
        url, headers={"JOB-TOKEN": os.environ.get("CI_JOB_TOKEN", "")}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    if not body.strip():
        raise RuntimeError(f"{project}:{path} came back empty")
    return body.decode("utf-8")


def main() -> int:
    api = "--api" in sys.argv
    root = Path(sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else ".")
    own_ref = os.environ.get("CONFORMANCE_OWN_REF", "main")
    failures = 0
    for name, (proj_a, path_a), (proj_b, path_b) in PAIRS:
        try:
            if api:
                # Both files are read at the SAME ref: the vendored copy
                # must match the canonical file in the tree under test,
                # not main (which may not have it yet).
                text_a = fetch_api(proj_a, path_a, own_ref)
                text_b = fetch_api(proj_b, path_b, own_ref)
            else:
                text_a = (root / PROJECT_PATHS[proj_a] / path_a).read_text()
                text_b = (root / PROJECT_PATHS[proj_b] / path_b).read_text()
        except Exception as error:
            print(f"ERROR {name}: {error}", file=sys.stderr)
            return 2
        if normalize(text_a) != normalize(text_b):
            failures += 1
            print(f"DRIFT {name}: adapter-only diff expected, got more:", file=sys.stderr)
            for line in difflib.unified_diff(
                normalize(text_a).splitlines(),
                normalize(text_b).splitlines(),
                fromfile=f"{proj_a}/{path_a}",
                tofile=f"{proj_b}/{path_b}",
                lineterm="",
            ):
                print(line, file=sys.stderr)
    if failures:
        return 1
    print("conformance-sync: all 3 suite pairs in sync (adapter lines only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
