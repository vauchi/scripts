#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$SCRIPT_DIR/ci-templates/verified-fetch.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_eq() {
    name="$1"
    expected="$2"
    actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass=$((pass + 1))
        printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual" >&2
    fi
}

fetch_step=$(awk '
    /^    - \|$/ { block += 1; next }
    block == 2 && /^      / { sub(/^      /, ""); print; next }
    block == 2 { exit }
' "$TEMPLATE")

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_ARGS"
EOF
chmod +x "$WORK/bin/curl"

run_fetch() {
    path="$1"
    : > "$WORK/curl-args"
    set +e
    PATH="$WORK/bin:$PATH" \
        CURL_ARGS="$WORK/curl-args" \
        CI_API_V4_URL="https://gitlab.example/api/v4" \
        CI_JOB_TOKEN="test-token" \
        FETCH_SCRIPT_PATH="$path" \
        FETCH_SCRIPT_OUTPUT="$WORK/fetched-script.sh" \
        VAUCHI_SCRIPTS_REF="ci-templates-v2026.07.3" \
        bash -c "$fetch_step" >/dev/null 2>&1
    rc=$?
    set -e
    fetched_url=$(grep '^https://' "$WORK/curl-args" || true)
}

run_fetch "scripts/ci/vet-autofix.sh"
assert_eq "nested repository path succeeds" "0" "$rc"
assert_eq "nested repository path is percent-encoded" \
    "https://gitlab.example/api/v4/projects/vauchi%2Fscripts/repository/files/scripts%2Fci%2Fvet-autofix.sh/raw?ref=ci-templates-v2026.07.3" \
    "$fetched_url"
assert_eq "CI job token uses GitLab job-token authentication" \
    "JOB-TOKEN: test-token" \
    "$(grep '^JOB-TOKEN: ' "$WORK/curl-args" || true)"

run_fetch "scripts/ci/not allowed.sh"
assert_eq "unsupported repository path fails closed" "2" "$rc"
assert_eq "unsupported repository path is not fetched" "" "$fetched_url"

printf '\nverified-fetch.test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
