#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Harness config parity — VHC01: the secondary AI-harness configs
# (.codex, .kimi-code, .junie) must reference the single canonical source
# in _private/.claude by symlink — never re-duplicate its rules/docs/skills
# as real directories — carry no broken symlinks, and keep their entry
# files (KIMI.md, AGENTS.md, .junie/AGENTS.md) thin pointers to CLAUDE.md
# rather than re-bloating into full copies.
# Rule page: _private/docs/lint-errors/vhc01-harness-parity.md
# Self-test: scripts/tests/check-harness-parity.test.sh
# Called by: `just session-end` and root CI.

set -euo pipefail

ROOT="${1:-.}"
errors=0
err() { printf '  %s\n' "$1" >&2; errors=$((errors + 1)); }

PAGE="_private/docs/lint-errors/vhc01-harness-parity.md"

# 1. Shared trees must be symlinks into canonical .claude, not real dirs.
#    A real directory here means the duplication has been reintroduced.
for harness in .codex .kimi-code; do
    for tree in rules docs skills; do
        p="$ROOT/$harness/$tree"
        [ -e "$p" ] || continue
        if [ ! -L "$p" ]; then
            err "$harness/$tree: VHC01: real directory, expected a symlink into _private/.claude — fix: replace with 'ln -s ../../.claude/$tree $harness/$tree'. [$PAGE]"
        fi
    done
done

# 2. No broken symlinks anywhere under the harness dirs.
for harness in .codex .kimi-code .junie; do
    d="$ROOT/$harness"
    [ -e "$d" ] || continue
    broken="$(find -L "$d/" -type l 2>/dev/null || true)"
    if [ -n "$broken" ]; then
        while IFS= read -r link; do
            [ -n "$link" ] && err "$link: VHC01: broken symlink — fix: repoint at the canonical target or remove. [$PAGE]"
        done <<EOF
$broken
EOF
    fi
done

# 3. Entry files stay thin: under the line budget and pointing at CLAUDE.md.
BUDGET=110
for ef in KIMI.md AGENTS.md .junie/AGENTS.md; do
    f="$ROOT/$ef"
    [ -f "$f" ] || continue
    lines="$(wc -l < "$f" | tr -d ' ')"
    if [ "$lines" -gt "$BUDGET" ]; then
        err "$ef: VHC01: $lines lines exceeds the thin-entry budget ($BUDGET) — an entry file re-duplicating CLAUDE.md instead of pointing at it. [$PAGE]"
    fi
    if ! grep -q 'CLAUDE.md' "$f"; then
        err "$ef: VHC01: no canonical pointer to CLAUDE.md — a thin entry file must defer to it. [$PAGE]"
    fi
done

# Tool-bug guard: a checker that suddenly flags everything is usually broken.
if [ "$errors" -gt 20 ]; then
    echo "check-harness-parity: POSSIBLE TOOL BUG: $errors issues — check flags/paths, not data" >&2
    exit 2
fi

if [ "$errors" -eq 0 ]; then
    echo "  Harness parity OK"
    exit 0
fi
echo "FAILED: $errors harness-parity violation(s)." >&2
exit 1
