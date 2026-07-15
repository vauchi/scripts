#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for markdownlint-rule-no-abs-paths.js (VDC01).
# Skips when markdownlint is not installed (CI selftests job has it).
# Rule page: _private/docs/lint-errors/vdc01-absolute-paths.md

set -euo pipefail

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RULE="$SCRIPT_DIR/../ci-templates/markdownlint-rule-no-abs-paths.js"

if ! command -v markdownlint >/dev/null 2>&1; then
    echo "  markdownlint not installed — SKIPPED (CI selftests has it)"
    exit 0
fi

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

run_md() { # $1=content → sets rc, out
    d="$(mktemp -d)"
    printf '%s\n' "$1" > "$d/x.md"
    # markdownlint-cli's ignore filter requires cwd-relative targets;
    # subshell keeps the caller's cwd untouched.
    out="$(cd "$d" && markdownlint -r "$RULE" -c /dev/null x.md 2>&1)"; rc=$?
    rm -rf "$d"
}

run_md '# Title

See the file at /home/alice/Workspace/vauchi-1/core/src/lib.rs today.'
assert_eq "linux abs path: exit 1" "1" "$rc"
assert_eq "linux abs path: VDC01 in output" "1" \
    "$(printf '%s' "$out" | grep -q 'VDC01' && echo 1 || echo 0)"

run_md '# Title

See /Users/bob/Projects/vauchi/docs/README.md for details.'
assert_eq "macos abs path: exit 1" "1" "$rc"

run_md '# Title

Relative paths like core/vauchi-app/src/ui/ are fine, as is ~/.claude/.'
assert_eq "relative + tilde paths: exit 0" "0" "$rc"

run_md '# Title

A URL <https://example.com/home/page> and /homework/notes.md are fine.'
assert_eq "lookalikes: exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
