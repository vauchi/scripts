#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-allow-failure-budget.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — expected %s, got %s\n' \
            "$name" "$expected" "$actual" >&2
        fail=$((fail + 1))
    fi
}

workspace() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/repo/ci" "$root/scripts/ci-templates"
    cat >"$root/repo/.gitlab-ci.yml" <<'YAML'
advisory:job:
  script: [true]
  allow_failure: true

manual:release:
  when: manual
  allow_failure: true
  script: [true]

partly:manual:
  rules:
    - if: $CI_COMMIT_TAG
      when: manual
    - if: $CI_MERGE_REQUEST_IID
  allow_failure: true
  script: [true]

blocking:job:
  script: [true]
YAML
    cat >"$root/repo/ci/included.yml" <<'YAML'
included:advisory:
  allow_failure: true
  script: [true]
YAML
    cat >"$root/scripts/ci-templates/template.yml" <<'YAML'
.template-advisory:
  allow_failure: true
YAML
    printf '%s' "$root"
}

count_of() {
    bash "$SCRIPT" --budget 1000 "$1" | sed -n 's/^Current count: //p'
}

exit_of() {
    local budget="$1" root="$2" rc=0
    bash "$SCRIPT" --budget "$budget" "$root" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

echo "check-allow-failure-budget.sh"

root="$(workspace)"
# Counted: advisory:job, partly:manual, included:advisory, .template-advisory.
# Not counted: manual:release — a job-level manual job is an opt-in gate.
# partly:manual still counts: only one rule is manual, and in merge
# requests it runs automatically with its failures silenced.
assert_eq "job-level manual excluded, rule-level manual, includes, templates counted" \
    "4" "$(count_of "$root")"
assert_eq "count within budget passes" "0" "$(exit_of 4 "$root")"
assert_eq "count over budget fails" "1" "$(exit_of 3 "$root")"
rm -rf "$root"

# Each behaviour on its own, so two wrong answers cannot cancel out.
only="$(mktemp -d)"
mkdir -p "$only/repo"
printf 'release:\n  when: manual\n  allow_failure: true\n' >"$only/repo/.gitlab-ci.yml"
assert_eq "a job-level manual job alone counts zero" "0" "$(count_of "$only")"
rm -rf "$only"

only="$(mktemp -d)"
mkdir -p "$only/repo/ci"
printf 'advisory:\n  allow_failure: true\n' >"$only/repo/ci/included.yml"
assert_eq "an advisory job in a ci/ include counts" "1" "$(count_of "$only")"
rm -rf "$only"

only="$(mktemp -d)"
mkdir -p "$only/repo"
cat >"$only/repo/.gitlab-ci.yml" <<'YAML'
deploy:
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
      allow_failure: true
  script: [true]
YAML
assert_eq "allow_failure on a manual rule alone counts zero" "0" "$(count_of "$only")"
rm -rf "$only"

only="$(mktemp -d)"
mkdir -p "$only/repo"
cat >"$only/repo/.gitlab-ci.yml" <<'YAML'
package:
  rules:
    - if: $CI_COMMIT_TAG
    - when: manual
      allow_failure: true
  script: [true]
YAML
assert_eq "a blocking tag rule with a manual fallback counts zero" "0" "$(count_of "$only")"
rm -rf "$only"

only="$(mktemp -d)"
mkdir -p "$only/repo"
cat >"$only/repo/.gitlab-ci.yml" <<'YAML'
verify:
  allow_failure: false
  rules:
    - if: $ESCAPE_HATCH == "true"
      allow_failure: true
    - if: $CI_PIPELINE_SOURCE == "pipeline"
  script: [true]
YAML
assert_eq "allow_failure on an automatic rule counts" "1" "$(count_of "$only")"
rm -rf "$only"

only="$(mktemp -d)"
mkdir -p "$only/repo"
cat >"$only/repo/.gitlab-ci.yml" <<'YAML'
flush:rules:
  rules:
  - if: $CI_COMMIT_TAG
    when: manual
    allow_failure: true
  - if: $CI_MERGE_REQUEST_IID
    allow_failure: true
  script: [true]
YAML
assert_eq "rule entries indented level with rules: are told apart" "1" "$(count_of "$only")"
rm -rf "$only"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
