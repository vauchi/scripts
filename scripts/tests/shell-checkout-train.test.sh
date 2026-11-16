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
        /^      (fetch_ref|fetch_and_checkout)\(\) \{$/ { n += 1; if (n == want) on = 1 }
        on { line = $0; sub(/^      /, "", line); sub(/fetch_and_checkout/, "fetch_ref", line); print line }
        on && /^      \}$/ { exit }
    ' "${2:-$TEMPLATE}"
}
extract_fetch_ref 1 > "$WORK/light.sh"
extract_fetch_ref 2 > "$WORK/full.sh"
extract_fetch_ref 1 "$SCRIPT_DIR/../../ci-templates/reuse.yml" > "$WORK/reuse.sh"
extract_fetch_ref 1 "$SCRIPT_DIR/../../.gitlab-ci.yml" > "$WORK/shellcheck.sh"
extract_fetch_ref 2 "$SCRIPT_DIR/../../.gitlab-ci.yml" > "$WORK/ci-lint.sh"
extract_checkout_block() {
    awk -v want="$1" '
        /^      REPO_URL=/ { n += 1; if (n == want) on = 1 }
        on && (/^    - / || /^  [a-zA-Z_]+:/ || /^[^ #]/) { exit }
        on { line = $0; sub(/^      /, "", line); print line }
    ' "${2:-$TEMPLATE}"
}
extract_checkout_block 1 > "$WORK/light-block.sh"
extract_checkout_block 2 > "$WORK/full-block.sh"
extract_checkout_block 1 "$SCRIPT_DIR/../../ci-templates/reuse.yml" > "$WORK/reuse-block.sh"
extract_checkout_block 1 "$SCRIPT_DIR/../../.gitlab-ci.yml" > "$WORK/shellcheck-block.sh"
extract_checkout_block 2 "$SCRIPT_DIR/../../.gitlab-ci.yml" > "$WORK/ci-lint-block.sh"
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
        # CI variables must expand inside the child shell.
        # shellcheck disable=SC2016
        env "$@" bash -c '
            fetch_with_retry() { git fetch origin "$1" --depth 20; }
            . "$0"
            fetch_ref >/dev/null 2>&1 && git rev-parse HEAD || echo FAILED
        ' "$WORK/$copy.sh"
    )
}

# A real origin loses a ref after the job has cached its objects and
# remote-tracking branches. Conditional invocation matches CI's `if !`
# caller, where Bash does not enforce implicit errexit (#1268).
checkout_after_ref_removed() {
    copy="$1"; removed_ref="$2"; shift 2
    rm -rf "$WORK/cached-job" "$WORK/broken-origin.git"
    git clone -q --mirror "$WORK/origin.git" "$WORK/broken-origin.git" || return 99
    mkdir -p "$WORK/cached-job" || return 99
    (
        cd "$WORK/cached-job" || exit 99
        git init -q || exit 99
        git remote add origin "file://$WORK/broken-origin.git" || exit 99
        git fetch -q origin main feature refs/merge-requests/7/train --depth 20 || exit 99
        git checkout -q origin/feature || exit 99
        git rev-parse origin/main >/dev/null || exit 99
        git cat-file -e "${TRAIN_SHA}^{commit}" || exit 99
        if [ "$removed_ref" = recover ]; then
            git config --add remote.origin.fetch 'invalid refspec' || exit 99
        elif [ -n "$removed_ref" ]; then
            git -C "$WORK/broken-origin.git" show-ref --verify --quiet "$removed_ref" || exit 99
            git -C "$WORK/broken-origin.git" update-ref -d "$removed_ref" || exit 99
        fi
        fixture_job_token="fixture-${WORK##*/}"
        # CI variables must expand inside the child shell.
        # shellcheck disable=SC2016
        if result=$(env \
            GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0="url.file://$WORK/broken-origin.git.insteadOf" \
            GIT_CONFIG_VALUE_0="https://gitlab-ci-token:${fixture_job_token}@gitlab.com/fixture/project.git" \
            CI_JOB_TOKEN="$fixture_job_token" \
            "$@" bash -c '
            set -e
            if [ "${CHECKOUT_BLOCK:-0}" = 1 ]; then
                timeout() { shift; "$@"; }
                sleep() { :; }
                . "${0%.sh}-block.sh"
                if [ "${CHECKOUT_RECOVERY:-0}" = 1 ]; then
                    test "$(git config --get-all remote.origin.fetch)" = "+refs/heads/*:refs/remotes/origin/*"
                fi
                echo "VALIDATION_STARTED $(git rev-parse HEAD)"
                exit 0
            fi
            fetch_with_retry() { git fetch origin "$1" --depth 20; }
            . "$0"
            fetch_ref >/dev/null 2>&1 && git rev-parse HEAD || echo FAILED
        ' "$WORK/$copy.sh" 2>&1); then
            printf '%s\n' "$result"
        else
            case "$result" in
                *VALIDATION_STARTED*) printf "UNEXPECTED VALIDATION: %s\n" "$result" ;;
                *"ERROR: source checkout failed after clean-clone recovery"*) echo FAILED ;;
                *) printf "UNEXPECTED FAILURE: %s\n" "$result" ;;
            esac
        fi
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

    # This suite itself runs inside a merge-request job, whose
    # CI_MERGE_REQUEST_* variables the inner shell would inherit; the push
    # case names them empty, which fetch_ref reads as unset.
    got=$(checkout_with "$copy" \
        CI_MERGE_REQUEST_EVENT_TYPE= CI_MERGE_REQUEST_IID= \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME= \
        CI_COMMIT_REF_NAME=main CI_COMMIT_SHA="$MAIN_SHA")
    assert_eq "$copy: a push pipeline checks out CI_COMMIT_SHA of its ref" \
        "$MAIN_SHA" "$got"
done

for copy in light full reuse shellcheck ci-lint; do
    got=$(checkout_after_ref_removed "$copy" refs/heads/feature \
        CHECKOUT_BLOCK=1 CI_PROJECT_PATH=fixture/project \
        CI_MERGE_REQUEST_EVENT_TYPE=detached CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$BRANCH_SHA")
    assert_eq "$copy: exhausted clean-clone recovery cannot start validation" "FAILED" "$got"

    got=$(checkout_after_ref_removed "$copy" '' \
        CHECKOUT_BLOCK=1 CI_PROJECT_PATH=fixture/project \
        CI_MERGE_REQUEST_EVENT_TYPE=detached CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$BRANCH_SHA")
    assert_eq "$copy: successful bootstrap validates the fetched source" \
        "VALIDATION_STARTED $BRANCH_SHA" "$(printf '%s\n' "$got" | tail -n 1)"

    got=$(checkout_after_ref_removed "$copy" recover \
        CHECKOUT_BLOCK=1 CHECKOUT_RECOVERY=1 CI_PROJECT_PATH=fixture/project \
        CI_MERGE_REQUEST_EVENT_TYPE= CI_MERGE_REQUEST_IID= \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME= \
        CI_COMMIT_REF_NAME=main CI_COMMIT_SHA="$MAIN_SHA")
    assert_eq "$copy: clean-clone recovery repairs invalid cached fetch configuration" \
        "VALIDATION_STARTED $MAIN_SHA" "$(printf '%s\n' "$got" | tail -n 1)"
done

for copy in reuse shellcheck ci-lint; do
got=$(checkout_with "$copy" \
    CI_MERGE_REQUEST_EVENT_TYPE=detached CI_MERGE_REQUEST_IID=7 \
    CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
    CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$BRANCH_SHA")
assert_eq "$copy: a healthy MR checks out its branch head" "$BRANCH_SHA" "$got"
got=$(checkout_with "$copy" \
    CI_MERGE_REQUEST_EVENT_TYPE= CI_MERGE_REQUEST_IID= \
    CI_MERGE_REQUEST_SOURCE_BRANCH_NAME= \
    CI_COMMIT_REF_NAME=main CI_COMMIT_SHA="$MAIN_SHA")
assert_eq "$copy: a healthy push checks out its commit" "$MAIN_SHA" "$got"
done

for copy in light full reuse shellcheck ci-lint; do
    got=$(checkout_after_ref_removed "$copy" refs/heads/feature \
        CI_MERGE_REQUEST_EVENT_TYPE=detached CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$BRANCH_SHA")
    assert_eq "$copy: failed MR fetch cannot use a cached branch" "FAILED" "$got"

    got=$(checkout_after_ref_removed "$copy" refs/heads/main \
        CI_MERGE_REQUEST_EVENT_TYPE= CI_MERGE_REQUEST_IID= \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME= \
        CI_COMMIT_REF_NAME=main CI_COMMIT_SHA="$MAIN_SHA")
    assert_eq "$copy: failed push fetch cannot use cached commit objects" "FAILED" "$got"
done

for copy in light full; do
    got=$(checkout_after_ref_removed "$copy" refs/merge-requests/7/train \
        CI_MERGE_REQUEST_EVENT_TYPE=merge_train CI_MERGE_REQUEST_IID=7 \
        CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature \
        CI_COMMIT_REF_NAME=feature CI_COMMIT_SHA="$TRAIN_SHA")
    assert_eq "$copy: failed train fetch cannot use cached commit objects" "FAILED" "$got"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
