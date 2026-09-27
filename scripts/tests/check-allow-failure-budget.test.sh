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

manual:via-rules:
  rules:
    - if: $CI_COMMIT_TAG
      when: manual
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
    sh "$SCRIPT" --budget 1000 "$1" | sed -n 's/^Current count: //p'
}

exit_of() {
    local budget="$1" root="$2" rc=0
    sh "$SCRIPT" --budget "$budget" "$root" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

echo "check-allow-failure-budget.sh"

root="$(workspace)"
# advisory:job + included:advisory + .template-advisory; both manual jobs
# are opt-in gates, not silently-failing checks, so they do not count.
assert_eq "manual jobs excluded, local includes and templates counted" \
    "3" "$(count_of "$root")"
assert_eq "count within budget passes" "0" "$(exit_of 3 "$root")"
assert_eq "count over budget fails" "1" "$(exit_of 2 "$root")"
rm -rf "$root"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
