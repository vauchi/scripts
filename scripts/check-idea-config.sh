#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared IDE config hygiene — VIC01: the tracked .idea/ project config must
# stay portable and shareable. Per-user IDE state (workspace.xml, tasks.xml,
# usage.statistics.xml) must never be tracked, and no .idea file may embed a
# machine-absolute path — IntelliJ portability requires $PROJECT_DIR$ /
# $MODULE_DIR$ macros, never /home/<user> or /Users/<user>.
# Rule page: _private/docs/lint-errors/vic01-idea-config-hygiene.md
# Self-test: scripts/tests/check-idea-config.test.sh
# Called by: root pre-commit / gate-push and root CI.

set -euo pipefail

ROOT="${1:-.}"
errors=0
err() { printf '  %s\n' "$1" >&2; errors=$((errors + 1)); }

PAGE="_private/docs/lint-errors/vic01-idea-config-hygiene.md"
PER_USER="workspace.xml tasks.xml usage.statistics.xml shelf"

[ -e "$ROOT/.idea" ] || { echo "  .idea config hygiene OK (no .idea)"; exit 0; }

# 1. Per-user IDE state must not be tracked by git (churn + machine leak).
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    for f in $PER_USER; do
        if git -C "$ROOT" ls-files --error-unmatch ".idea/$f" >/dev/null 2>&1; then
            err ".idea/$f: VIC01: per-user IDE state is tracked — fix: 'git rm -r --cached .idea/$f' and keep it in .idea/.gitignore. [$PAGE]"
        fi
    done
fi

# 2. No machine-absolute paths in TRACKED .idea files (must use IntelliJ
#    macros). Per-user files (workspace.xml) are gitignored and legitimately
#    hold machine paths, so scan only what git tracks.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    tracked="$(git -C "$ROOT" ls-files -- '.idea' 2>/dev/null || true)"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if grep -qE '(/home/[A-Za-z]|/Users/[A-Za-z]|file:///)' "$ROOT/$rel" 2>/dev/null; then
            err "$rel: VIC01: machine-absolute path in a tracked .idea file — fix: use \$PROJECT_DIR\$ / \$MODULE_DIR\$ macros. [$PAGE]"
        fi
    done <<EOF
$tracked
EOF
fi

if [ "$errors" -gt 30 ]; then
    echo "check-idea-config: POSSIBLE TOOL BUG: $errors issues — check flags/paths, not data" >&2
    exit 2
fi

if [ "$errors" -eq 0 ]; then
    echo "  .idea config hygiene OK"
    exit 0
fi
echo "FAILED: $errors .idea hygiene violation(s)." >&2
exit 1
