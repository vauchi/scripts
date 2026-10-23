#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The pre-push hook used to skip server CI lint whenever .gitlab-ci.yml had
# `local:` includes, so core!1945 went out with two YAML errors (private#779).
# Server lint resolves `local:` includes from the default branch, so it
# can run whenever every included file is already there. This pins the
# three verdicts check-ci-local-includes.sh gives the hook, each against a
# real git repo: lintable, missing on disk, and new on this branch.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$DIR/scripts/check-ci-local-includes.sh"

pass=0
fail=0

expect_exit() {
    local name="$1" want="$2" repo="$3"
    local got=0
    sh "$CHECK" "$repo" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s — exit %s, want %s\n' "$name" "$got" "$want" >&2
        fail=$((fail + 1))
    fi
}

# A repo whose origin/main holds .gitlab-ci.yml including ci/a.yml.
make_repo() {
    local repo
    repo=$(mktemp -d)
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    mkdir -p "$repo/ci"
    printf 'a:\n  script: [true]\n' > "$repo/ci/a.yml"
    printf 'include:\n  - local: ci/a.yml\n' > "$repo/.gitlab-ci.yml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    printf '%s' "$repo"
}

repo=$(make_repo)
expect_exit "every include already on main → server lint can run" 0 "$repo"
rm -rf "$repo"

repo=$(make_repo)
printf '  - local: "/ci/gone.yml"\n' >> "$repo/.gitlab-ci.yml"
expect_exit "include missing on disk → fail" 1 "$repo"
rm -rf "$repo"

repo=$(make_repo)
printf 'b:\n  script: [true]\n' > "$repo/ci/b.yml"
printf "  - local: 'ci/b.yml'\n" >> "$repo/.gitlab-ci.yml"
expect_exit "include only on this branch → server lint cannot see it" 3 "$repo"
rm -rf "$repo"

repo=$(make_repo)
printf 'stages: [test]\n' > "$repo/.gitlab-ci.yml"
expect_exit "no local includes → server lint can run" 0 "$repo"
rm -rf "$repo"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
