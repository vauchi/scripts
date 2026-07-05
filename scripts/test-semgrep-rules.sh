#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the semgrep-rules fixture suite: each <rules>.yml with a sibling
# <rules>.rs fixture (annotated with `// ruleid:` / `// ok:`) is
# verified via the engine's --test mode. Pairs are copied to a temp dir
# because --test resolves rule↔test pairing by same-stem filenames in
# one directory (config-file + separate test dir crashes opengrep
# v1.25's relative-path pairing).
# Skips gracefully when no engine is installed locally; the scripts
# repo test:selftests CI job treats an installed engine as mandatory.
# Engine preference: opengrep (the project's SAST engine), then semgrep.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="$(cd "$SCRIPT_DIR/../semgrep-rules" && pwd)"

ENGINE=""
if command -v opengrep >/dev/null 2>&1; then
    ENGINE=opengrep
elif command -v semgrep >/dev/null 2>&1; then
    ENGINE=semgrep
fi

if [[ -z "$ENGINE" ]]; then
    echo "  test-semgrep-rules: no opengrep/semgrep installed — SKIPPED"
    echo "  (CI test:selftests runs this with the engine installed)"
    exit 0
fi

failed=0
found_fixture=0
for fixture in "$RULES_DIR"/*.rs; do
    [[ -f "$fixture" ]] || continue
    found_fixture=1
    base="$(basename "$fixture" .rs)"
    rules="$RULES_DIR/$base.yml"
    if [[ ! -f "$rules" ]]; then
        echo "  test-semgrep-rules: fixture $fixture has no rule file $rules" >&2
        failed=1
        continue
    fi
    pair="$(mktemp -d)"
    cp "$rules" "$fixture" "$pair/"
    echo "  Testing $base.yml against $base.rs ($ENGINE)"
    if ! "$ENGINE" scan --test "$pair" >/dev/null 2>&1; then
        # re-run loud for the failure report
        "$ENGINE" scan --test "$pair" 2>&1 | tail -20
        failed=1
    fi
    rm -rf "$pair"
done

if [[ "$found_fixture" -eq 0 ]]; then
    echo "  test-semgrep-rules: no fixtures found in $RULES_DIR" >&2
    exit 1
fi

if [[ "$failed" -ne 0 ]]; then
    echo "FAILED: semgrep rule fixtures do not match annotations."
    exit 1
fi
echo "  Semgrep rule fixtures OK"
