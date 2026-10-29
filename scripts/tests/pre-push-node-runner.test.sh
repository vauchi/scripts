#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# The pre-push hook fails closed for a repo type it has no check runner
# for (2026-10-27). The website is a static site with a Playwright
# suite and had no runner, so no code could be pushed there at all
# (vauchi/private#922). This pins the contract of the Node runner: it is
# chosen by package.json plus playwright.config.js, it refuses to run
# without node_modules instead of installing, it regenerates the pages
# before the suite so the tests see the branch's templates, it runs the
# suite, and it sits before the fail-closed branch.
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

runner_line=$(grep -n 'elif \[\[ -f "\$REPO_ROOT/package.json" && -f "\$REPO_ROOT/playwright.config.js" \]\]' "$HOOK" | head -1 | cut -d: -f1)
else_line=$(grep -n 'no check runner for this project type' "$HOOK" | head -1 | cut -d: -f1)

check "the hook has a runner chosen by package.json and playwright.config.js" test -n "$runner_line"
check "the hook still fails closed for unknown repo types" test -n "$else_line"
if [ -n "$runner_line" ] && [ -n "$else_line" ]; then
    check "the Node runner comes before the fail-closed branch" test "$runner_line" -lt "$else_line"
    branch=$(sed -n "${runner_line},${else_line}p" "$HOOK")
    check "the runner refuses to run without node_modules" grep -q 'node_modules' <<<"$branch"
    # The error message may name 'npm ci' as the fix; a command line must not.
    check "the runner does not install dependencies itself" bash -c '! grep -vE "echo" <<<"$1" | grep -qE "npm (ci|install)"' _ "$branch"
    check "the runner regenerates the pages before the suite" grep -q 'build-pages.py' <<<"$branch"
    check "the runner runs the Playwright suite" grep -qE 'npx playwright test' <<<"$branch"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
