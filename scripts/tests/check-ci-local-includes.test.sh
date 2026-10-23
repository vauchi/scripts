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
    repo=$(mktemp -d) || true
    if [ -z "$repo" ] || [ ! -d "$repo" ]; then
        echo "make_repo: mktemp failed, stopping before git runs in the wrong place" >&2
        exit 2
    fi
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    mkdir -p "$repo/ci"
    printf 'a:\n  script: [true]\n' > "$repo/ci/a.yml"
    printf 'include:\n  - local: ci/a.yml\n' > "$repo/.gitlab-ci.yml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

make_repo
expect_exit "every include already on main → server lint can run" 0 "$repo"
rm -rf "$repo"

make_repo
printf '  - local: "/ci/gone.yml"\n' >> "$repo/.gitlab-ci.yml"
expect_exit "include missing on disk → fail" 1 "$repo"
rm -rf "$repo"

make_repo
printf 'b:\n  script: [true]\n' > "$repo/ci/b.yml"
printf "  - local: 'ci/b.yml'\n" >> "$repo/.gitlab-ci.yml"
expect_exit "include only on this branch → server lint cannot see it" 3 "$repo"
rm -rf "$repo"

make_repo
printf 'stages: [test]\n' > "$repo/.gitlab-ci.yml"
expect_exit "no local includes → server lint can run" 0 "$repo"
rm -rf "$repo"

# Server lint reads main's copy of an include, so an edited one would be
# judged by the version this push does not carry.
make_repo
printf 'a:\n  script: [false]\n' > "$repo/ci/a.yml"
git -C "$repo" commit -qam "edit include"
expect_exit "include edited on this branch → server lint cannot see it" 3 "$repo"
rm -rf "$repo"

# `changed` lists the CI files this branch touches — the top file and its
# local includes — so the hook lints an include-only change too.
expect_changed() {
    local name="$1" want="$2" repo="$3" got
    got=$(sh "$CHECK" "$repo" changed 2>/dev/null | tr '\n' ' ')
    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s — got [%s], want [%s]\n' "$name" "$got" "$want" >&2
        fail=$((fail + 1))
    fi
}

make_repo
expect_changed "nothing changed → no CI files" "" "$repo"
printf 'a:\n  script: [false]\n' > "$repo/ci/a.yml"
printf 'unrelated\n' > "$repo/README"
git -C "$repo" add -A
git -C "$repo" commit -qm "edit include and an unrelated file"
expect_changed "only an include changed → that include" "ci/a.yml " "$repo"
printf '# note\n' >> "$repo/.gitlab-ci.yml"
git -C "$repo" commit -qam "edit top file"
expect_changed "top file and include changed → both" ".gitlab-ci.yml ci/a.yml " "$repo"
rm -rf "$repo"

# A change main made after this branch started is not this branch's: the
# list compares against the merge base, not main's tip.
make_repo
git -C "$repo" switch -q -c topic
git -C "$repo" switch -q -c main-ahead origin/main
printf 'a:\n  script: [false]\n' > "$repo/ci/a.yml"
git -C "$repo" commit -qam "main edits the include"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" switch -q topic
expect_changed "main moved on, branch touched no CI → no CI files" "" "$repo"
rm -rf "$repo"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
