#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pre-push markdown gate: lint the .md paths given on stdin (relative to the
# repo root) with the repo's markdownlint config and custom line-length rule.
# Usage: printf '%s\n' <paths> | md-lint.sh <repo-root>
#
# Paths excluded by .markdownlintignore are set aside first, because
# markdownlint handed only excluded paths lints nothing, prints its usage and
# exits 0 — which this gate used to report as "Markdown lint OK"
# (vauchi/private#60). The ignore file uses gitignore syntax, so
# `git check-ignore` applies it exactly.

set -uo pipefail

REPO_ROOT="$1"
# The workspace root holds repos.toml; a repo may sit below it, as the
# tools under utils/ do (private#1034). Fall back to the parent directory
# for a checkout outside a workspace.
WS_ROOT="$REPO_ROOT/.."
probe=$(cd "$REPO_ROOT" && pwd)
while [[ "$probe" != "/" ]]; do
    probe=$(dirname "$probe")
    if [[ -f "$probe/repos.toml" ]]; then
        WS_ROOT="$probe"
        break
    fi
done
FILES=$(grep -v '^$' || true)
[[ -z "$FILES" ]] && exit 0

EXCLUDED=""
if [[ -f "$REPO_ROOT/.markdownlintignore" ]]; then
    EXCLUDED=$(printf '%s\n' "$FILES" | git -C "$REPO_ROOT" \
        -c core.excludesFile="$REPO_ROOT/.markdownlintignore" \
        check-ignore --no-index --stdin 2>/dev/null || true)
fi
if [[ -n "$EXCLUDED" ]]; then
    LINT=$(printf '%s\n' "$FILES" | grep -vxF -f <(printf '%s\n' "$EXCLUDED") || true)
else
    LINT="$FILES"
fi
EXCLUDED_COUNT=$(printf '%s' "$EXCLUDED" | grep -c . || true)

if [[ -z "$LINT" ]]; then
    echo "  All $EXCLUDED_COUNT changed .md file(s) are excluded by .markdownlintignore — nothing linted"
    exit 0
fi

MD_ARGS=()
for config in "$REPO_ROOT/.markdownlint.json" "$REPO_ROOT/.markdownlint.jsonc" \
    "$WS_ROOT/_private/.markdownlint.json" "$WS_ROOT/.markdownlint.json"; do
    if [[ -f "$config" ]]; then
        MD_ARGS+=(-c "$config")
        break
    fi
done
CUSTOM_RULE="$WS_ROOT/_private/scripts/markdownlint-rule-line-length.js"
[[ -f "$CUSTOM_RULE" ]] && MD_ARGS+=(-r "$CUSTOM_RULE")

LINT_COUNT=$(printf '%s\n' "$LINT" | grep -c .)
output=$(cd "$REPO_ROOT" && printf '%s\n' "$LINT" | xargs markdownlint ${MD_ARGS[@]+"${MD_ARGS[@]}"} 2>&1)
rc=$?
if printf '%s' "$output" | grep -q '^Usage: markdownlint'; then
    echo "FAILED: markdownlint linted none of the $LINT_COUNT file(s) it was given"
    exit 1
fi
if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$output"
    echo ""
    echo "FAILED: markdownlint found issues. Run 'just lint-markdown fix' to auto-fix."
    exit 1
fi
if [[ "$EXCLUDED_COUNT" -gt 0 ]]; then
    echo "  Markdown lint OK ($LINT_COUNT file(s); $EXCLUDED_COUNT excluded by .markdownlintignore)"
else
    echo "  Markdown lint OK ($LINT_COUNT file(s))"
fi
