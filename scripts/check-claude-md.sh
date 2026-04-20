#!/usr/bin/env sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Validate CLAUDE.md references and detect orphaned .claude/docs/ entries.
# Single source of truth called by both `just check-claude-md` (locally,
# via the vauchi/scripts sub-repo checkout) and the GitLab CI
# `lint:claude-md` job (which fetches this file from vauchi/scripts at
# runtime since the main repo's checkout does not include sub-repos).
#
# Portability: runs in alpine:3.21 (BusyBox) and host GNU/BSD shells.
# Do NOT use GNU-only grep flags (--exclude, --include, -P). See
# .claude/rules/portable-shell.md §BusyBox.
#
# Exit codes:
#   0 — all references valid, no orphaned docs
#   1 — reference or orphan issues found
#   2 — check itself may be broken (sanity threshold exceeded)

set -eu

CLAUDE_MD="CLAUDE.md"
DOCS_DIR=".claude/docs"
RULES_DIR=".claude/rules"
SKILLS_DIR=".claude/skills"

# Sanity threshold: more orphans than this indicates a tool bug, not
# a wave of forgotten references. Turns silent data-damage failures
# (like BusyBox ignoring an unrecognized flag) into an explicit signal.
SANITY_THRESHOLD=5

errors=0

# 1. Check .claude/ paths referenced in CLAUDE.md exist.
for ref in $(grep -oE '`[^`]*\.md`' "$CLAUDE_MD" | tr -d '`' | grep -E '\.claude/' || true); do
    if [ ! -f "$ref" ]; then
        echo "BROKEN REF: $ref (referenced in CLAUDE.md but missing)"
        errors=$((errors + 1))
    fi
done

# 2. Detect orphaned docs. Search CLAUDE.md, rules/, skills/, and
# sibling docs (transitive refs); filter the self-file from the
# matches list so a doc cannot reference itself.
# Portable: BusyBox grep lacks --exclude, hence the two-step approach.
for f in "$DOCS_DIR"/*.md; do
    name=$(basename "$f")
    matches=$(grep -rl "$name" "$CLAUDE_MD" "$RULES_DIR" "$SKILLS_DIR" "$DOCS_DIR" 2>/dev/null \
        | grep -v "^$DOCS_DIR/$name\$" || true)
    if [ -z "$matches" ]; then
        echo "ORPHANED: $DOCS_DIR/$name (not referenced from CLAUDE.md, rules, skills, or sibling docs)"
        errors=$((errors + 1))
    fi
done

# 3. Check _private paths referenced in CLAUDE.md exist — only when
# the _private submodule is present (not in the CI alpine checkout).
if [ -d "_private" ]; then
    for ref in $(grep -oE '`_private/[^`]*`' "$CLAUDE_MD" | tr -d '`' || true); do
        if [ ! -f "$ref" ] && [ ! -d "$ref" ]; then
            echo "BROKEN REF: $ref (referenced in CLAUDE.md but missing)"
            errors=$((errors + 1))
        fi
    done
fi

if [ "$errors" -eq 0 ]; then
    echo "CLAUDE.md: all references valid, no orphaned docs"
    exit 0
fi

# Sanity check: an unusually large orphan burst points at the checker,
# not the docs (e.g. BusyBox rejecting a GNU-only grep flag and
# short-circuiting the recursive search).
if [ "$errors" -gt "$SANITY_THRESHOLD" ]; then
    echo ""
    echo "POSSIBLE TOOL BUG: $errors issues — every doc flagged is suspicious."
    echo "Check this script's grep flags against the runtime environment"
    echo "before assuming the docs are wrong (see portable-shell.md §BusyBox)."
    exit 2
fi

echo ""
echo "$errors issue(s) found. Fix references or add docs to CLAUDE.md."
exit 1
