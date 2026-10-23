#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Decides whether server CI lint can judge a repo's .gitlab-ci.yml.
#
# GitLab's lint endpoint resolves `local:` includes from the default
# branch, so it judges the file correctly whenever every included file is
# already on origin/main. The pre-push hook skipped server lint for any
# `local:` include, and core!1945 went out with two YAML errors that lint
# would have caught (private#779).
#
# Usage:
#   check-ci-local-includes.sh <repo-root>
#
# Exit: 0 server lint can run, 1 an include is missing on disk,
#       3 an include exists only on this branch (server lint cannot see it),
#       2 usage/IO error.
#
# Self-test: scripts/tests/check-ci-local-includes.test.sh
# Portability: POSIX shell + sed + git (BusyBox/BSD/GNU safe).
set -eu

ROOT="${1:-}"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/.gitlab-ci.yml" ]; then
    printf 'check-ci-local-includes: usage: %s <repo-root with .gitlab-ci.yml>\n' "$0" >&2
    exit 2
fi

missing=0
branch_only=0
includes=$(grep -E '^[[:space:]]*-[[:space:]]*local:' "$ROOT/.gitlab-ci.yml" || true)
for inc in $(printf '%s\n' "$includes" |
    sed -E 's/^[[:space:]]*-[[:space:]]*local:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//'); do
    path="${inc#/}"
    if [ ! -f "$ROOT/$path" ]; then
        printf '  MISSING local include: %s\n' "$inc"
        missing=1
    elif ! git -C "$ROOT" cat-file -e "origin/main:$path" 2>/dev/null; then
        printf '  local include not on origin/main yet: %s\n' "$inc"
        branch_only=1
    fi
done

[ "$missing" = 0 ] || exit 1
[ "$branch_only" = 0 ] || exit 3
exit 0
