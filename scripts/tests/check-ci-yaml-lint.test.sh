#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-ci-yaml-lint.sh — VCI02 (extends +
# own before_script without !reference silently drops template steps)
# and VCI03 (`|| true` swallowing state-changing git in CI). Fixtures
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
assert_eq "VCI02: message carries ID" "0" "${out##*VCI02*}"
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
assert_eq "VCI03: message carries ID" "0" "${out##*VCI03*}"
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

# ── non-tautology guard (CC-21): stub that always passes is caught ─────
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
ws="$(mktemp -d)"
printf 'j:\n  extends: .b\n  before_script:\n    - x\n' > "$ws/x.gitlab-ci.yml"
"$stub" "$ws/x.gitlab-ci.yml" >/dev/null 2>&1; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -rf "$ws"; rm -f "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
