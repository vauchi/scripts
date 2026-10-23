#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Decides whether server CI lint can judge a repo's .gitlab-ci.yml, and
# lists the CI files a branch touches.
#
# GitLab's lint endpoint resolves `local:` includes from the default
# branch, so it judges what this push carries only when every included
# file is on origin/main unchanged. The pre-push hook skipped server lint
# for any `local:` include, and core!1945 went out with two YAML errors
# that lint would have caught (private#779).
#
# Usage:
#   check-ci-local-includes.sh <repo-root>          verdict, by exit code
#   check-ci-local-includes.sh <repo-root> changed  CI files changed since
#                                                   origin/main, one per line
#
# Exit (verdict): 0 server lint can run, 1 an include is missing on disk,
#       3 an include is new or edited on this branch (server lint would read
#       main's copy), 2 usage/IO error.
#
# Self-test: scripts/tests/check-ci-local-includes.test.sh
# Portability: POSIX shell + sed + git (BusyBox/BSD/GNU safe).
set -eu

ROOT="${1:-}"
MODE="${2:-verdict}"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/.gitlab-ci.yml" ]; then
    printf 'check-ci-local-includes: usage: %s <repo-root with .gitlab-ci.yml> [changed]\n' "$0" >&2
    exit 2
fi

local_includes() {
    grep -E '^[[:space:]]*-[[:space:]]*local:' "$ROOT/.gitlab-ci.yml" |
        sed -E 's/^[[:space:]]*-[[:space:]]*local:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//; s#^/##' || true
}

changed_since_main() {
    git -C "$ROOT" diff --name-only origin/main HEAD -- "$1"
}

if [ "$MODE" = changed ]; then
    for path in .gitlab-ci.yml $(local_includes); do
        [ -n "$(changed_since_main "$path")" ] && printf '%s\n' "$path"
    done
    exit 0
fi

missing=0
branch_only=0
for path in $(local_includes); do
    if [ ! -f "$ROOT/$path" ]; then
        printf '  MISSING local include: %s\n' "$path"
        missing=1
    elif ! git -C "$ROOT" cat-file -e "origin/main:$path" 2>/dev/null; then
        printf '  local include not on origin/main yet: %s\n' "$path"
        branch_only=1
    elif [ -n "$(changed_since_main "$path")" ]; then
        printf '  local include edited on this branch: %s\n' "$path"
        branch_only=1
    fi
done

[ "$missing" = 0 ] || exit 1
[ "$branch_only" = 0 ] || exit 3
exit 0
