#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-ci-yaml-lint.sh — VCI02 (extends +
# own before_script without !reference silently drops template steps)
# VCI03 (`|| true` swallowing state-changing git in CI), and VCI04
# (side-effect jobs matching scheduled main refs). Fixtures
# are intentionally-bad yml. Rule pages: _private/docs/lint-errors/vci*.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-ci-yaml-lint.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

run_yml() { # $1=name $2=content → sets rc, out
    ws="$(mktemp -d)"
    printf '%s\n' "$2" > "$ws/x.gitlab-ci.yml"
    out="$("$SCRIPT" "$ws/x.gitlab-ci.yml" 2>&1)"; rc=$?
    rm -rf "$ws"
}

# ── clean: extends + before_script WITH !reference passes ──────────────
run_yml clean 'myjob:
  extends: .rust-base
  before_script:
    - !reference [.rust-base, before_script]
    - ./extra-setup.sh
  script:
    - git fetch origin main
    - git reset --hard origin/main'
assert_eq "clean: exit 0" "0" "$rc"

# ── clean: extends without own before_script passes ────────────────────
run_yml clean2 'myjob:
  extends: .rust-base
  script:
    - echo ok'
assert_eq "clean-no-override: exit 0" "0" "$rc"

# ── clean: own before_script without extends passes (self-contained) ───
run_yml clean3 'myjob:
  before_script:
    - ./setup.sh
  script:
    - echo ok'
assert_eq "clean-no-extends: exit 0" "0" "$rc"

# ── VCI02: extends + before_script, no !reference ──────────────────────
run_yml vci02 'myjob:
  extends: .rust-base
  before_script:
    - ./my-setup.sh
  script:
    - echo ok'
assert_eq "VCI02: exit 1" "1" "$rc"
assert_eq "VCI02: message carries ID" "1" \
    "$(printf '%s' "$out" | grep -q 'VCI02:' && echo 1 || echo 0)"
assert_eq "VCI02: message names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VCI02: .+ — fix: .+' && echo 1 || echo 0)"

# ── VCI02 suppression: # vci02-ok inside the job passes ────────────────
run_yml vci02ok 'myjob:  # vci02-ok: full replacement intended, template steps hostile here
  extends: .rust-base
  before_script:
    - ./my-setup.sh'
assert_eq "VCI02 suppressed: exit 0" "0" "$rc"

# ── VCI03: || true on state-changing git ───────────────────────────────
run_yml vci03 'myjob:
  script:
    - git pull --ff-only 2>/dev/null || true
    - ./deploy.sh'
assert_eq "VCI03: exit 1" "1" "$rc"
assert_eq "VCI03: message carries ID" "1" \
    "$(printf '%s' "$out" | grep -q 'VCI03:' && echo 1 || echo 0)"
assert_eq "VCI03: message names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VCI03: .+ — fix: .+' && echo 1 || echo 0)"

# ── VCI03: || : variant also fires ─────────────────────────────────────
run_yml vci03b 'myjob:
  script:
    - git checkout main || :'
assert_eq "VCI03 (|| :): exit 1" "1" "$rc"

# ── VCI03: non-state-changing git with || true passes ──────────────────
run_yml vci03c 'myjob:
  script:
    - git remote set-url origin "$URL" 2>/dev/null || true'
assert_eq "VCI03 non-state-changing: exit 0" "0" "$rc"

# ── VCI03 suppression: # vci03-ok on the line passes ───────────────────
run_yml vci03ok 'myjob:
  script:
    - git fetch origin main --depth=1 || true  # vci03-ok: degraded-mode fallback below'
assert_eq "VCI03 suppressed: exit 0" "0" "$rc"

# ── VCI04: a side-effect template must exclude schedules first ────────
run_yml vci04 '.auto-tag:
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
assert_eq "VCI04: exit 1" "1" "$rc"
assert_eq "VCI04: message carries ID" "1" \
    "$(printf '%s' "$out" | grep -q 'VCI04:' && echo 1 || echo 0)"

# ── VCI04: a late schedule guard cannot undo the first branch match ───
run_yml vci04order '.trigger-on-merge:
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_PIPELINE_SOURCE == "schedule"
      when: never'
assert_eq "VCI04 late guard: exit 1" "1" "$rc"

# ── VCI04: conditional schedule rejection does not fail closed ───────
run_yml vci04conditional '.main-only:
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule" && $SPECIAL_MODE == "true"
      when: never
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
assert_eq "VCI04 conditional guard: exit 1" "1" "$rc"

# ── VCI04: literal main branch checks have the same schedule hazard ───
run_yml vci04main 'auto-tag:version:
  rules:
    - if: $CI_COMMIT_BRANCH == "main"'
assert_eq "VCI04 literal main: exit 1" "1" "$rc"

# ── VCI04: schedule-never before the branch match passes ──────────────
run_yml vci04safe 'deploy:trigger:
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
      when: never
    - if: $CI_COMMIT_TAG =~ /^v/
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
assert_eq "VCI04 guarded: exit 0" "0" "$rc"

# ── VCI04: ordinary read-only branch jobs are outside this rule ───────
run_yml vci04scope 'test:unit:
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
assert_eq "VCI04 scoped: exit 0" "0" "$rc"

# ── two jobs: only the violating one is reported ───────────────────────
run_yml multi 'good:
  extends: .base
  before_script:
    - !reference [.base, before_script]
bad:
  extends: .base
  before_script:
    - ./own.sh'
assert_eq "multi-job: exit 1" "1" "$rc"
assert_eq "multi-job: names the bad job" "1" \
    "$(printf '%s' "$out" | grep -c 'bad')"

# ── VCI05: own workflow rules drop the template's default-branch guard ─
# e2e's shape on 2026-10-11 (vauchi/private#632): rust-base.yml sets
# on_new_commit: interruptible, the repo replaces rules: without the
# default-branch none rule, and a merge on e2e main canceled Core's
# downstream verification pipelines, so Core's release tag never ran.
run_yml vci05 'include:
  - project: vauchi/scripts
    file:
      - /ci-templates/rust-base.yml
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_PIPELINE_SOURCE == "push"
    - if: $CI_PIPELINE_SOURCE == "pipeline"'
assert_eq "VCI05 template include: exit 1" "1" "$rc"
assert_eq "VCI05: message carries ID" "1" \
    "$(printf '%s' "$out" | grep -c 'VCI05')"

# ── VCI05: an own interruptible policy without a main exemption ───────
# android's shape on 2026-10-11 (#632): no rules at all, so the v0.80.2
# release's triggered main pipeline was canceled by the next merge before
# update:bindings-version opened the bump MR.
run_yml vci05bare 'workflow:
  auto_cancel:
    on_new_commit: interruptible'
assert_eq "VCI05 own policy, no rules: exit 1" "1" "$rc"

run_yml vci05own 'workflow:
  auto_cancel:
    on_new_commit: interruptible
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"'
assert_eq "VCI05 own policy with rules: exit 1" "1" "$rc"

# ── VCI05: an own policy with the main exemption passes ────────────────
run_yml vci05ownok 'workflow:
  auto_cancel:
    on_new_commit: interruptible
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      auto_cancel:
        on_new_commit: none
    - when: always'
assert_eq "VCI05 own policy guarded: exit 0" "0" "$rc"

# ── VCI05: canceling superseded main deploys on purpose is said so ─────
run_yml vci05ownsup 'workflow:
  # vci05-ok: a newer main deploy supersedes the old one; nothing waits on it
  auto_cancel:
    on_new_commit: interruptible'
assert_eq "VCI05 own policy suppressed: exit 0" "0" "$rc"

# ── VCI05: the default-branch none rule passes ─────────────────────────
run_yml vci05ok 'include:
  - project: vauchi/scripts
    file:
      - /ci-templates/rust-base.yml
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      auto_cancel:
        on_new_commit: none
    - if: $CI_PIPELINE_SOURCE == "push"'
assert_eq "VCI05 guarded: exit 0" "0" "$rc"

# ── VCI05: setting only auto_cancel keeps the template rules → passes ──
run_yml vci05merge 'include:
  - project: vauchi/scripts
    file:
      - /ci-templates/rust-base.yml
workflow:
  auto_cancel:
    on_new_commit: interruptible'
assert_eq "VCI05 policy only: exit 0" "0" "$rc"

# ── VCI05: template + own policy + own rules, no exemption (web-demo) ─
run_yml vci05chose 'include:
  - project: vauchi/scripts
    file:
      - /ci-templates/rust-base.yml
workflow:
  auto_cancel:
    on_new_commit: interruptible
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
assert_eq "VCI05 template + own policy: exit 1" "1" "$rc"

# ── VCI05: own rules with no auto-cancel policy in force pass ──────────
run_yml vci05none 'workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"'
assert_eq "VCI05 no policy: exit 0" "0" "$rc"

# ── VCI05: suppression with a reason ───────────────────────────────────
run_yml vci05sup 'include:
  - project: vauchi/scripts
    file:
      - /ci-templates/rust-base.yml
workflow:
  # vci05-ok: this repo has no release tag and nothing waits on main
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"'
assert_eq "VCI05 suppressed: exit 0" "0" "$rc"

# ── non-tautology guard (CC-21): stub that always passes is caught ─────
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
ws="$(mktemp -d)"
printf 'j:\n  extends: .b\n  before_script:\n    - x\n' > "$ws/x.gitlab-ci.yml"
"$stub" "$ws/x.gitlab-ci.yml" >/dev/null 2>&1; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -rf "$ws"; rm -f "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
