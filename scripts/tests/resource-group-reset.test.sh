#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# resource-group-reset.sh scans the iOS and macOS projects for stuck
# resource-group jobs. When the GitLab API refuses it, the job log must
# name the HTTP status rather than a bare "failed" (VSH13,
# vauchi/private#27). Runs dry-run only, against a fake curl.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$DIR/scripts/ci/resource-group-reset.sh"

PASS=0
FAIL=0
ws=$(mktemp -d)
trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/bin"
cp "$DIR/scripts/tests/fake-curl.py" "$ws/bin/curl"
chmod +x "$ws/bin/curl"

run_reset() {
    FAKE_CURL_STATUS="$1" FAKE_CURL_BODY="$2" FAKE_CURL_LOG="$ws/requests" \
        PATH="$ws/bin:$PATH" PROJECT_ACCESS_TOKEN=token \
        CI_API_V4_URL=https://gitlab.example/api/v4 \
        bash "$SCRIPT" --dry-run >"$ws/log" 2>&1
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

expect_no_post() {
    if grep -q '^POST' "$ws/requests" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s — dry-run sent a POST\n' "$1" >&2
    else
        PASS=$((PASS + 1))
    fi
}

run_reset 401 '{"message":"401 Unauthorized"}'
expect_logged "401 project lookup" "projects/77813130 returned HTTP 401"
expect_logged "401 jobs list" "per_page=100&page=1 returned HTTP 401"
expect_no_post "401"

: >"$ws/requests"
run_reset 200 '{"path":"ios"}'
expect_logged "200 project name" "Scanning ios (id 77813130)"
expect_logged "200 summary" "projects scanned:      2"
expect_no_post "200"

# An old job in a matching resource group is stuck; a fresh one is not.
now=$(date -u +%Y-%m-%dT%H:%M:%S)
printf '%s\t%s\t%s\n' \
    "page=2" 200 '[]' \
    "jobs?scope" 200 "[{\"id\":5,\"status\":\"running\",\"created_at\":\"2020-01-01T00:00:00.000Z\",\"name\":\"old\"},{\"id\":6,\"status\":\"pending\",\"created_at\":\"${now}.000Z\",\"name\":\"fresh\"},{\"id\":7,\"status\":\"running\",\"created_at\":\"not-a-date\",\"name\":\"garbled\"}]" \
    "/jobs/" 200 '{"resource_group":"ios-spm-v1"}' \
    "projects/" 200 '{"path":"ios"}' >"$ws/routes"
: >"$ws/requests"
FAKE_CURL_ROUTES="$ws/routes" run_reset 200 '[]'
expect_logged "old job" "STUCK job 5 (old)"
expect_logged "fresh job" "SKIP job 6 (fresh)"
# A timestamp that does not parse must never read as "stuck" — once
# --execute is on, that would cancel it.
expect_logged "unparsable job" "SKIP job 7 (garbled)"
expect_no_post "stuck dry-run"

echo "resource-group-reset: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
