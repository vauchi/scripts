#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# The pre-push hook fails closed for a repo type it has no check runner
# for. The tools and forks in vauchi/utils are a Python project
# (markdown-plan, pyproject.toml in python/) and an npm project with a
# check script (drift-detector), and neither could be pushed at all
# (vauchi/private#1034). This pins both runners' contract:
#
# Python: chosen by pyproject.toml at the root or in python/; runs the
# project's pytest suite with its own .venv when present, otherwise
# python3; never installs anything; fails naming the missing pytest.
#
# npm: chosen by a package.json whose scripts include "check"; refuses to
# run without node_modules instead of installing; runs npm run check.
#
# Both sit after the website's Playwright runner, so a package.json with
# playwright.config.js keeps its own runner, and before the fail-closed
# branch.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${HOOK:-$DIR/hooks/pre-push}"
PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name" >&2
    fi
}

web_line=$(grep -n 'elif \[\[ -f "\$REPO_ROOT/package.json" && -f "\$REPO_ROOT/playwright.config.js" \]\]' "$HOOK" | head -1 | cut -d: -f1)
py_line=$(grep -n 'elif \[\[ -f "\$REPO_ROOT/pyproject.toml" || -f "\$REPO_ROOT/python/pyproject.toml" \]\]' "$HOOK" | head -1 | cut -d: -f1)
npm_line=$(grep -n 'elif \[\[ -f "\$REPO_ROOT/package.json" \]\] && grep -q ."check":. "\$REPO_ROOT/package.json"' "$HOOK" | head -1 | cut -d: -f1)
else_line=$(grep -n 'no check runner for this project type' "$HOOK" | head -1 | cut -d: -f1)

check "the hook has a Python runner chosen by pyproject.toml at the root or in python/" test -n "$py_line"
check "the hook has an npm runner chosen by a check script in package.json" test -n "$npm_line"
check "the hook still fails closed for unknown repo types" test -n "$else_line"

if [ -n "$py_line" ] && [ -n "$web_line" ] && [ -n "$else_line" ]; then
    check "the Python runner comes after the website runner" test "$web_line" -lt "$py_line"
    check "the Python runner comes before the fail-closed branch" test "$py_line" -lt "$else_line"
    end=${npm_line:-$else_line}
    branch=$(sed -n "${py_line},${end}p" "$HOOK")
    check "the Python runner prefers the project's .venv" grep -q '\.venv/bin/python' <<<"$branch"
    check "the Python runner runs pytest" grep -qE 'time_step "pytest"' <<<"$branch"
    check "the Python runner names a missing pytest" grep -q 'pytest is not installed' <<<"$branch"
    check "the Python runner installs nothing" bash -c '! grep -vE "echo" <<<"$1" | grep -qE "pip install|uv (pip|sync|add)"' _ "$branch"
fi

if [ -n "$npm_line" ] && [ -n "$web_line" ] && [ -n "$else_line" ]; then
    check "the npm runner comes after the website runner" test "$web_line" -lt "$npm_line"
    check "the npm runner comes before the fail-closed branch" test "$npm_line" -lt "$else_line"
    branch=$(sed -n "${npm_line},${else_line}p" "$HOOK")
    check "the npm runner refuses to run without node_modules" grep -q 'node_modules' <<<"$branch"
    check "the npm runner installs nothing" bash -c '! grep -vE "echo" <<<"$1" | grep -qE "npm (ci|install)"' _ "$branch"
    check "the npm runner runs npm run check" grep -qE 'time_step "npm run check" npm --prefix "\$REPO_ROOT" run check' <<<"$branch"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
