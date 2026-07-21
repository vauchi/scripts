#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VDC05 — canonical doc-naming check: new markdown files follow
# YYYY-MM-DD-<name>.md unless exempt. THE single source of truth for
# the exemption lists — the previous four independently-maintained
# copies (lint-docs.yml inline, _private/docs/scripts/, gate-push.sh,
# pre-push) drifted apart and caused 7 CI failures in the 2026-03..07
# sample; consumers now call this script (fetched via
# fetch_vauchi_script in CI, workspace-local from hooks).
# Rule page: _private/docs/lint-errors/vdc05-doc-naming.md
# Self-test: scripts/tests/check-doc-naming.test.sh
#
# Usage:
#   check-doc-naming.sh --files f1.md f2.md …   # explicit list (tests)
#   check-doc-naming.sh                          # CI: changed files

set -euo pipefail

# Union of the historical EXCEPTIONS lists (well-known + living docs +
# problem-record companions + all-caps index/status files).
EXCEPTIONS='README.md|CLAUDE.md|CONTEXT.md|CONTRIBUTING.md|roadmap.md|PRINCIPLES.md|VISIBILITY_POLICY.md|INDEX.md|STRUCTURE.md|ARCHITECTURE.md|SECURITY.md|CHECKLIST.md|MANIFEST.md|assumptions.md|master-plan.plan.md|work-board.md|work-board-archive.md|intervention-ledger.md|investigation.md|implementation-plan.md|retrospective.md|post-mortem.md|rejected-solutions.md|design.md|plan.md|principles-audit.md'
EXCEPTION_SUFFIXES='-audit\.md|-report\.md|-checklist\.md|-analysis\.md|\.plan\.md'
# Union of the historical EXEMPT_DIRS lists.
EXEMPT_DIRS='diagrams|ideas|strategy|infra|knowledge|audit-review-frameworks|decisions|guides|reference|runbooks|testing|admin-guides|components|legal|problems|lint-errors|\.claude|\.kimi-code|\.junie|audits'

errors=0

check_file() {
    file="$1"
    filename=$(basename "$file")
    dirname=$(dirname "$file")

    case "$filename" in
        *.md) ;;
        *) return 0 ;;
    esac
    if printf '%s' "$filename" | grep -qE "^($EXCEPTIONS)$"; then return 0; fi
    if printf '%s' "$filename" | grep -qE "($EXCEPTION_SUFFIXES)$"; then return 0; fi
    if printf '%s' "$dirname" | grep -qE "(^|/)($EXEMPT_DIRS)(/|$)"; then return 0; fi
    if [ "$dirname" = "." ]; then return 0; fi

    if ! printf '%s' "$filename" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'; then
        printf '  %s: VDC05: does not follow YYYY-MM-DD-<name>.md — fix: add a date prefix, or add a justified exemption to ci-templates/check-doc-naming.sh. [_private/docs/lint-errors/vdc05-doc-naming.md]\n' "$file"
        errors=$((errors + 1))
        return 0
    fi

    # Placement rules for dated files.
    case "$dirname" in
        */designs|designs) case "$filename" in *-design.md) ;; *)
            printf '  %s: VDC05: files in designs/ must end with -design.md — fix: rename. [_private/docs/lint-errors/vdc05-doc-naming.md]\n' "$file"
            errors=$((errors + 1)) ;; esac ;;
    esac
    return 0
}

if [ "${1:-}" = "--files" ]; then
    shift
    files="$*"
elif [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
    git fetch origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" --depth=1 2>/dev/null || true # vci03-ok: degraded to last-commit diff below
    files=$(git diff --name-only --diff-filter=A "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"...HEAD -- '*.md' 2>/dev/null || echo "")
elif [ -n "${CI_COMMIT_BEFORE_SHA:-}" ] && [ "$CI_COMMIT_BEFORE_SHA" != "0000000000000000000000000000000000000000" ]; then
    files=$(git diff --name-only --diff-filter=A "$CI_COMMIT_BEFORE_SHA"...HEAD -- '*.md' 2>/dev/null || echo "")
else
    files=$(git diff --name-only --diff-filter=A HEAD~1...HEAD -- '*.md' 2>/dev/null || echo "")
fi

if [ -z "$files" ]; then
    echo "No new markdown files to check."
    exit 0
fi

for f in $files; do
    check_file "$f"
done

if [ "$errors" -gt 0 ]; then
    echo ""
    printf 'FAILED: %d file(s) violate the doc-naming convention.\n' "$errors"
    exit 1
fi
echo "All new files follow the naming convention."
