#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Verify that workspace-internal path dependencies in Cargo.toml declare a
# version matching workspace.package.version. Catches incomplete version
# bumps that break golden fixture / binding contract tests.
#
# Usage: check-workspace-versions.sh [path/to/Cargo.toml]

set -euo pipefail

CARGO_TOML="${1:-Cargo.toml}"

if [[ ! -f "$CARGO_TOML" ]]; then
    echo "ERROR: $CARGO_TOML not found"
    exit 1
fi

python3 - "$CARGO_TOML" <<'PY'
import sys, tomllib
from pathlib import Path

cargo_toml = Path(sys.argv[1])
data = tomllib.loads(cargo_toml.read_text(encoding="utf-8"))

workspace_pkg = data.get("workspace", {}).get("package", {})
workspace_version = workspace_pkg.get("version")
if not workspace_version:
    print(f"No workspace.package.version in {cargo_toml} — skipping.")
    sys.exit(0)

deps = data.get("workspace", {}).get("dependencies", {})
mismatches = []
for name, spec in deps.items():
    if isinstance(spec, str):
        continue
    if not isinstance(spec, dict):
        continue
    if "path" not in spec:
        continue
    dep_version = spec.get("version")
    if dep_version and dep_version != workspace_version:
        mismatches.append((name, dep_version, workspace_version))

if mismatches:
    print(f"ERROR: workspace.dependencies versions do not match workspace.package.version ({workspace_version}) in {cargo_toml}:")
    for name, dep_version, expected in mismatches:
        print(f"  {name}: {dep_version} (expected {expected})")
    print("")
    print("Fix: bump the version field for each workspace member in [workspace.dependencies].")
    sys.exit(1)

print(f"OK: workspace dependency versions aligned at {workspace_version} ({cargo_toml}).")
PY
