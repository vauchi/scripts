#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# generate-badges.sh falls back to "unknown" / "N/A" / "none" badges when
# the GitLab API fails, so a badge job never breaks a pipeline. The
# fallback is deliberate; staying silent about why is not — the job log
# must name the HTTP status (VSH13, vauchi/private#27).

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$DIR/scripts/ci/generate-badges.sh"

PASS=0
FAIL=0
ws=$(mktemp -d)
trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/bin"
cp "$DIR/scripts/tests/fake-curl.py" "$ws/bin/curl"
chmod +x "$ws/bin/curl"

run_badges() {
    rm -rf "$ws/out"
    FAKE_CURL_STATUS="$1" FAKE_CURL_BODY="$2" PATH="$ws/bin:$PATH" \
        CI_JOB_TOKEN=token CI_API_V4_URL=https://gitlab.example/api/v4 \
        CI_PROJECT_ID=1 CI_DEFAULT_BRANCH=main \
        bash "$SCRIPT" "$ws/out" >"$ws/log" 2>&1
}

expect_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s — expected %s, got %s\n' "$1" "$3" "$2" >&2
    fi
}

expect_logged() {
    if grep -qF "$2" "$ws/log"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s — log lacks "%s":\n' "$1" "$2" >&2
        sed 's/^/    /' "$ws/log" >&2
    fi
}

badge() { jq -r .message "$ws/out/$1.json"; }

# A refused token: fallback badges, and the log says why.
run_badges 403 '{"message":"403 Forbidden"}'
expect_eq "403 exit" "$?" 0
expect_logged "403 pipelines" "pipelines?ref=main&per_page=5 returned HTTP 403"
expect_logged "403 tags" "repository/tags?per_page=50&order_by=version returned HTTP 403"
expect_eq "403 pipeline badge" "$(badge pipeline)" unknown
expect_eq "403 coverage badge" "$(badge coverage)" N/A
expect_eq "403 release badge" "$(badge release)" none

# No connection at all is reported as HTTP 000, not swallowed.
run_badges 000 ''
expect_eq "000 exit" "$?" 0
expect_logged "000 pipelines" "pipelines?ref=main&per_page=5 returned HTTP 000"
expect_eq "000 pipeline badge" "$(badge pipeline)" unknown

# A healthy API still yields real badges.
run_badges 200 '[{"id":7,"status":"success","coverage":81.5,"name":"v1.2.3"}]'
expect_eq "200 exit" "$?" 0
expect_eq "200 pipeline badge" "$(badge pipeline)" passed
expect_eq "200 coverage badge" "$(badge coverage)" "81.5%"
expect_eq "200 release badge" "$(badge release)" v1.2.3

echo "generate-badges: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
