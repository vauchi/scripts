#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hook-parity drift detector for the two agent harnesses.
#
# .claude/hooks (Claude Code) and .kimi-code/hooks (Kimi Code) are SEPARATE
# copies with INCOMPATIBLE input ABIs — Claude passes tool JSON on stdin and
# can rewrite input via hookSpecificOutput.updatedInput; Kimi passes the
# command as argv and is exit-code-only. So the files cannot be a single
# shared source, and same-named hooks cannot be content-compared meaningfully.
#
# What CAN drift silently — and what this catches — is *presence*: a hook
# added to one harness but never mirrored to the other (e.g. a new guardrail
# lands in .claude/hooks only). Reports the by-name difference both ways.
# Informational by default (exit 0); pass --strict to exit 1 on any drift
# (for CI/session-end gating).
#
# Usage: scripts/scripts/check-hook-parity.sh [--strict] [root]

set -uo pipefail

STRICT=0
ROOT="."
for a in "$@"; do
    case "$a" in
        --strict) STRICT=1 ;;
        *) ROOT="$a" ;;
    esac
done

CLAUDE_DIR="$ROOT/.claude/hooks"
KIMI_DIR="$ROOT/.kimi-code/hooks"

if [[ ! -d "$CLAUDE_DIR" ]] || [[ ! -d "$KIMI_DIR" ]]; then
    echo "hook-parity: one of the hook dirs is absent ($CLAUDE_DIR, $KIMI_DIR) — skipping"
    exit 0
fi

# Basenames of top-level *.sh hooks (exclude the tests/ subdir and libs).
list_hooks() {
    find "$1" -maxdepth 1 -name '*.sh' -type f -exec basename {} \; 2>/dev/null | sort
}

claude_only=$(comm -23 <(list_hooks "$CLAUDE_DIR") <(list_hooks "$KIMI_DIR"))
kimi_only=$(comm -13 <(list_hooks "$CLAUDE_DIR") <(list_hooks "$KIMI_DIR"))

drift=0
if [[ -n "$claude_only" ]]; then
    drift=1
    echo "Hooks in .claude/hooks with NO .kimi-code counterpart (port candidates):"
    echo "$claude_only" | sed 's/^/  + /'
fi
if [[ -n "$kimi_only" ]]; then
    drift=1
    echo "Hooks in .kimi-code/hooks with NO .claude counterpart:"
    echo "$kimi_only" | sed 's/^/  - /'
fi

if [[ "$drift" -eq 0 ]]; then
    echo "hook-parity: both harnesses carry the same hook set by name."
    exit 0
fi

echo ""
echo "Note: same-named hooks are NOT content-compared — the two harnesses have"
echo "incompatible hook ABIs (Claude stdin-JSON + updatedInput; Kimi argv +"
echo "exit-code). Presence drift above is the actionable signal."

[[ "$STRICT" -eq 1 ]] && exit 1
exit 0
