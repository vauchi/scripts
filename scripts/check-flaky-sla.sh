#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Flaky-quarantine SLA — VFL01: a test quarantined with
# `#[ignore = "FLAKY: <issue-url>"]` must be fixed or deleted within 48h
# (flaky-test-quarantine-policy). This turns that honor-system SLA into an
# enforced gate: it fails when a FLAKY-quarantined test has been in place
# longer than the SLA, or lacks the mandatory issue URL in its marker.
# Rule page: _private/docs/lint-errors/vfl01-flaky-sla.md
# Self-test: scripts/tests/check-flaky-sla.test.sh
# Called by: a scheduled CI job (cheap, alpine) and `just session-end`.
#
# Usage: check-flaky-sla.sh [REPO_DIR] [MAX_HOURS] [NOW_EPOCH]
#   NOW_EPOCH overrides "now" (for deterministic tests); default: date +%s.

set -euo pipefail

REPO_DIR="${1:-.}"
MAX_HOURS="${2:-48}"
NOW="${3:-$(date +%s)}"
errors=0
err() { printf '  %s\n' "$1" >&2; errors=$((errors + 1)); }

PAGE="_private/docs/lint-errors/vfl01-flaky-sla.md"

git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "  flaky-SLA: not a git repo ($REPO_DIR) — skipped"
    exit 0
}

# Find every FLAKY quarantine marker (file:line:content).
hits="$(grep -rnE 'ignore[[:space:]]*=[[:space:]]*"FLAKY' \
    --include='*.rs' "$REPO_DIR" 2>/dev/null || true)"
[ -n "$hits" ] || { echo "  flaky-SLA OK (no quarantined tests)"; exit 0; }

while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${hit#*:*:}"

    # Policy requires a tracking issue URL in the marker.
    if ! printf '%s' "$text" | grep -qE 'https?://'; then
        err "$file:$line: VFL01: FLAKY quarantine lacks a tracking issue URL — fix: '#[ignore = \"FLAKY: <issue-url>\"]'. [$PAGE]"
    fi

    # Age = now - the commit that introduced this line (git blame committer-time).
    ct="$(git -C "$REPO_DIR" blame -L "$line,$line" --porcelain -- "$file" 2>/dev/null \
        | awk '/^committer-time /{print $2; exit}')"
    if [ -z "$ct" ]; then
        continue
    fi
    age_h=$(( (NOW - ct) / 3600 ))
    if [ "$age_h" -gt "$MAX_HOURS" ]; then
        err "$file:$line: VFL01: FLAKY quarantine is ${age_h}h old, past the ${MAX_HOURS}h SLA — fix the root cause or delete the test. [$PAGE]"
    fi
done <<EOF
$hits
EOF

if [ "$errors" -eq 0 ]; then
    echo "  flaky-SLA OK (all quarantines within ${MAX_HOURS}h)"
    exit 0
fi
echo "FAILED: $errors flaky-SLA violation(s)." >&2
exit 1
