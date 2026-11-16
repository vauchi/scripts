#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
hook=${HOOK:-$root/hooks/pre-push}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

awk '/^        run_tests\(\) \{/ { found=1 } found { print } found && /^        \}$/ { exit }' "$hook" > "$work/function.sh"
cat > "$work/harness.sh" <<'HARNESS'
set -eu
REPO_ROOT='/fixture/e2e with spaces'
REPO_DIR=$CASE
E2E_BIN_DIR='/explicit/cache with spaces'
sh() {
    [ "$1" = "$REPO_ROOT/ci/build-pinned-binaries.sh" ]
    [ "$2" = "$E2E_BIN_DIR" ]
    [ "$REFRESH_FAIL" = 0 ] || return 51
    export REFRESHED=yes
}
TEST_CMD=(bash "$RUNNER")
HARNESS
cat "$work/function.sh" >> "$work/harness.sh"
printf '\nrun_tests\n' >> "$work/harness.sh"
cat > "$work/runner.sh" <<'RUNNER'
set -eu
if [ "$CASE" = e2e ]; then
    [ "${REFRESHED:-no}" = yes ] || { echo 'pinned cache was not refreshed' >&2; exit 22; }
else
    [ "${REFRESHED:-no}" = no ] || exit 23
fi
printf 'tests ran\n' > "$RESULT"
RUNNER

env -u REFRESHED CASE=e2e REFRESH_FAIL=0 RUNNER="$work/runner.sh" RESULT="$work/result" bash "$work/harness.sh" > "$work/output" 2>&1
[ "$(cat "$work/result")" = 'tests ran' ]
rm "$work/result"
rc=0
env -u REFRESHED CASE=e2e REFRESH_FAIL=1 RUNNER="$work/runner.sh" RESULT="$work/result" bash "$work/harness.sh" > "$work/output" 2>&1 || rc=$?
[ "$rc" = 51 ] && [ ! -e "$work/result" ]
env -u REFRESHED CASE=cli REFRESH_FAIL=0 RUNNER="$work/runner.sh" RESULT="$work/result" bash "$work/harness.sh" > "$work/output" 2>&1
[ "$(cat "$work/result")" = 'tests ran' ]
echo 'pre-push-e2e-cohort-refresh: 3 passed'
