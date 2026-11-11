#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for `fetch_ref` in ci-templates/rust-base.yml, the
# checkout every shell-executor job runs under GIT_STRATEGY: none. Both
# copies (.shell-checkout and .self-hosted) are extracted from the template
# and run against a local origin that carries a main branch, a feature
# branch behind it, and the merge train's ref for that branch.
#
# On a merge-train pipeline the job must test the car GitLab merges,
# refs/merge-requests/<iid>/train at CI_COMMIT_SHA, not the branch head the
# train is about to rebase past (vauchi/private#1214). On every other
# merge-request pipeline the branch head stays the checkout, and a push
# pipeline checks out CI_COMMIT_SHA from CI_COMMIT_REF_NAME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../../ci-templates/rust-base.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# The Nth `fetch_ref() {` ... `}` block of the template, de-indented.
extract_fetch_ref() {
    awk -v want="$1" '
        /^      fetch_ref\(\) \{$/ { n += 1; if (n == want) on = 1 }
        on { line = $0; sub(/^      /, "", line); print line }
        on && /^      \}$/ { exit }
    ' "$TEMPLATE"
}
extract_fetch_ref 1 > "$WORK/light.sh"
extract_fetch_ref 2 > "$WORK/full.sh"
assert_eq "both fetch_ref copies were found in the template" "yes" \
    "$(grep -q 'fetch_ref' "$WORK/light.sh" && grep -q 'fetch_ref' "$WORK/full.sh" && echo yes || echo no)"

# ── Fixture: main moved past a feature branch; the train car is the
#    branch rebased onto the new main. ───────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q --bare "$WORK/origin.git"
git -C "$WORK/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$WORK/seed"
( cd "$WORK/seed" || exit 1
  git remote add origin "file://$WORK/origin.git"
  git checkout -q -b main
  echo a > a; git add a; git commit -q -m base
  git checkout -q -b feature
  echo b > b; git add b; git commit -q -m "feature work"
  git checkout -q main
  echo a2 > a; git add a; git commit -q -m "main moved on"
  git checkout -q -b train main
  git cherry-pick feature >/dev/null
  git push -q origin main feature
  git push -q origin train:refs/merge-requests/7/train
)
MAIN_SHA=$(git -C "$WORK/seed" rev-parse main)
BRANCH_SHA=$(git -C "$WORK/seed" rev-parse feature)
TRAIN_SHA=$(git -C "$WORK/seed" rev-parse train)
assert_eq "the fixture's train car differs from the branch head" "no" \
    "$([ "$TRAIN_SHA" = "$BRANCH_SHA" ] && echo yes || echo no)"

# $1 = copy (light|full), then the job's CI variables as NAME=VALUE pairs.
# Prints the sha the checkout left at HEAD, or FAILED.
checkout_with() {
    copy="$1"; shift
    rm -rf "$WORK/job" && mkdir -p "$WORK/job"
    (
        cd "$WORK/job" || exit 99
        git init -q
        git remote add origin "file://$WORK/origin.git"
        # The full copy fetches through this wrapper; the light copy calls
        # git directly.
        env "$@" bash -c '
            fetch_with_retry() { git fetch origin "$1" --depth 20; }
            . "$0"
            fetch_ref >/dev/null 2>&1 && git rev-parse HEAD || echo FAILED
        ' "$WORK/$copy.sh"
    )
}

for copy in light full; do
    got=$(checkout_with "$copy" \
        CI_MERGE_REQUEST_EVENT_TYPE=merge_train CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$TRAIN_SHA")
    assert_eq "$copy: a merge-train pipeline checks out the train car at CI_COMMIT_SHA" \
        "$TRAIN_SHA" "$got"

    got=$(checkout_with "$copy" \
        CI_MERGE_REQUEST_EVENT_TYPE=merged_result CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$TRAIN_SHA")
    assert_eq "$copy: a merged-result pipeline still checks out the branch head" \
        "$BRANCH_SHA" "$got"

    got=$(checkout_with "$copy" \
        CI_MERGE_REQUEST_EVENT_TYPE=detached CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$BRANCH_SHA")
    assert_eq "$copy: a detached pipeline checks out the branch head" \
        "$BRANCH_SHA" "$got"

    got=$(checkout_with "$copy" \
        CI_COMMIT_REF_NAME=main CI_COMMIT_SHA="$MAIN_SHA")
    assert_eq "$copy: a push pipeline checks out CI_COMMIT_SHA of its ref" \
        "$MAIN_SHA" "$got"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
