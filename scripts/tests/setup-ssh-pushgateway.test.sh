#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Tests for setup-ssh-pushgateway.sh
#
# Run: bash scripts/scripts/ci/test-setup-ssh-pushgateway.sh
# All assertions use plain bash — no external test framework needed.

set -euo pipefail

set -uo pipefail
# Note: not using -e because we need to track pass/fail counts and
# (( 0 )) returns exit code 1 which would abort the script.

# Lives in scripts/tests/ because that is what CI globs
# (.gitlab-ci.yml runs `scripts/tests/*.test.sh`). It previously sat in
# scripts/ci/ as test-setup-ssh-pushgateway.sh, matched no glob, and had
# therefore never run — with three failures in it.
SCRIPT_DIR="$(cd "$(dirname "$0")/../ci" && pwd)"
PASS=0
FAIL=0
ORIG_HOME="$HOME"

# ── Helpers ──────────────────────────────────────────────────────

setup_test() {
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    # Clear any leftover function definition from previous source
    unset -f setup_ssh_pushgateway 2>/dev/null || true

    # Isolate from ambient credentials. HOME alone is not enough: CI
    # exports PUSHGATEWAY_SSH_KEY on every branch (it is the unprotected
    # restricted key), so the cases that mean "no key is configured" found
    # one, decoded it, and failed on a key file they did not expect. That
    # only showed up once this suite was actually wired into CI — locally
    # neither variable is set, so it passed 18/18 and proved nothing about
    # the environment it would run in.
    #
    # Each test exports exactly what it needs after calling this.
    unset DEPLOY_SSH_PRIVATE_KEY PUSHGATEWAY_SSH_KEY PUSHGATEWAY_URL
    unset PUSHGATEWAY_SSH_MODE
}

teardown_test() {
    rm -rf "$TEST_HOME"
    export HOME="$ORIG_HOME"
    # Clear trap set by the function under test
    trap - EXIT
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label — file not found: $path"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_not_exists() {
    local label="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label — file should not exist: $path"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_contains() {
    local label="$1" path="$2" pattern="$3"
    if grep -q "$pattern" "$path" 2>/dev/null; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label — pattern '$pattern' not found in $path"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_mode() {
    local label="$1" path="$2" expected_mode="$3"
    local actual_mode
    # macOS stat vs Linux stat.
    #
    # The BSD-first `||` chain this replaces never fell through on Linux:
    # `stat -f` is a VALID GNU flag ("display filesystem status"), so it
    # exits 0 and prints `  File: "..."`, which was then compared against
    # "600" and failed on every Linux run. Same shape as the fallbacks
    # CC-27 is about — the first branch appears to succeed and the wrong
    # value is used silently.
    #
    # GNU first (BSD stat has no -c, so it genuinely errors there), and the
    # result must look like a mode before it is trusted.
    actual_mode=$(stat -c "%a" "$path" 2>/dev/null || true)
    if ! [[ "$actual_mode" =~ ^[0-7]+$ ]]; then
        actual_mode=$(stat -f "%Lp" "$path" 2>/dev/null || true)
    fi
    if ! [[ "$actual_mode" =~ ^[0-7]+$ ]]; then
        echo "  FAIL: $label — could not read a file mode from stat"
        FAIL=$(( FAIL + 1 ))
        return
    fi
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label — expected mode $expected_mode, got $actual_mode"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ── Tests ────────────────────────────────────────────────────────

echo "=== Test 1: Skips when DEPLOY_SSH_PRIVATE_KEY is unset ==="
setup_test
unset DEPLOY_SSH_PRIVATE_KEY 2>/dev/null || true
export PUSHGATEWAY_SSH_HOST="test-host"
export PUSHGATEWAY_SSH_IP="1.2.3.4"
export PUSHGATEWAY_SSH_USER="deploy"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway 2>/dev/null

assert_file_not_exists "no key file created" "$HOME/.ssh/id_ed25519"
teardown_test

echo ""
echo "=== Test 2: Creates key file with correct permissions from valid base64 ==="
setup_test
# GitLab file-type CI variables store data in a temp file;
# the env var contains the FILE PATH, not the data itself.
KEY_FILE=$(mktemp)
echo -n "this is a fake key for testing" | base64 > "$KEY_FILE"
export DEPLOY_SSH_PRIVATE_KEY="$KEY_FILE"
export PUSHGATEWAY_SSH_HOST="test-host"
export PUSHGATEWAY_SSH_IP="1.2.3.4"
export PUSHGATEWAY_SSH_USER="deploy"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway 2>/dev/null

assert_file_exists "key file created" "$HOME/.ssh/id_ed25519"
assert_file_mode "key file is 600" "$HOME/.ssh/id_ed25519" "600"
assert_file_exists "ssh config created" "$HOME/.ssh/config"
assert_file_contains "config has Host" "$HOME/.ssh/config" "Host test-host"
assert_file_contains "config has HostName" "$HOME/.ssh/config" "HostName 1.2.3.4"
assert_file_contains "config has User" "$HOME/.ssh/config" "User deploy"
assert_file_mode "config is 600" "$HOME/.ssh/config" "600"

# Verify the decoded key content
assert_eq "key content correct" "this is a fake key for testing" "$(cat "$HOME/.ssh/id_ed25519")"
teardown_test

echo ""
echo "=== Test 3: Skips if key file already exists ==="
setup_test
mkdir -p "$HOME/.ssh"
echo "existing-key" > "$HOME/.ssh/id_ed25519"
KEY_FILE=$(mktemp)
echo -n "different key" | base64 > "$KEY_FILE"
export DEPLOY_SSH_PRIVATE_KEY="$KEY_FILE"
export PUSHGATEWAY_SSH_HOST="test-host"
export PUSHGATEWAY_SSH_IP="1.2.3.4"
export PUSHGATEWAY_SSH_USER="deploy"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway 2>/dev/null

assert_eq "key not overwritten" "existing-key" "$(cat "$HOME/.ssh/id_ed25519")"
teardown_test

echo ""
echo "=== Test 4: Skips when DEPLOY_SSH_PRIVATE_KEY is empty string ==="
setup_test
export DEPLOY_SSH_PRIVATE_KEY=""
export PUSHGATEWAY_SSH_HOST="test-host"
export PUSHGATEWAY_SSH_IP="1.2.3.4"
export PUSHGATEWAY_SSH_USER="deploy"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway 2>/dev/null

assert_file_not_exists "no key on empty var" "$HOME/.ssh/id_ed25519"
teardown_test

echo ""
echo "=== Test 5: Fails on invalid base64 and cleans up ==="
setup_test
KEY_FILE=$(mktemp)
echo "!!!not-valid-base64!!!" > "$KEY_FILE"
export DEPLOY_SSH_PRIVATE_KEY="$KEY_FILE"
export PUSHGATEWAY_SSH_HOST="test-host"
export PUSHGATEWAY_SSH_IP="1.2.3.4"
export PUSHGATEWAY_SSH_USER="deploy"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
if setup_ssh_pushgateway 2>/dev/null; then
    echo "  FAIL: should have returned nonzero on bad base64"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: returns nonzero on bad base64"
    PASS=$(( PASS + 1 ))
fi
assert_file_not_exists "no key left after bad base64" "$HOME/.ssh/id_ed25519"
teardown_test

# ── Transport stamping (CC-27: prove the fallback surfaces its branch) ──
#
# The four-day silence in the 2026-08-01 outage was possible because a
# delivered metric looked the same whichever transport carried it. These
# assert the payload now says, and that a total failure says so too.

setup_test "transport stamping"
STUB_DIR=$(mktemp -d)
CAPTURE="$STUB_DIR/payload"

# Stubs record stdin instead of reaching the network. Like curl with
# -o /dev/stderr -w '%{http_code}', they answer with a body on stderr and the
# HTTP status on stdout.
cat >"$STUB_DIR/curl" <<STUB
#!/bin/sh
# Record the command line, and the config file curl was pointed at with -K.
printf '%s\n' "\$*" > "$CAPTURE.argv"
: > "$CAPTURE.config"
prev=""
for arg in "\$@"; do
    [ "\$prev" = "-K" ] && cat "\$arg" > "$CAPTURE.config"
    prev="\$arg"
done
cat > "$CAPTURE"
[ -z "\${STUB_CURL_BODY:-}" ] || echo "\$STUB_CURL_BODY" >&2
printf '%s' "\${STUB_CURL_STATUS:-200}"
exit \${STUB_CURL_RC:-0}
STUB
cat >"$STUB_DIR/ssh" <<STUB
#!/bin/sh
cat > "$CAPTURE"
[ -z "\${STUB_SSH_ERR:-}" ] || echo "\$STUB_SSH_ERR" >&2
printf '%s' "\${STUB_SSH_STATUS:-200}"
exit \${STUB_SSH_RC:-0}
STUB
chmod +x "$STUB_DIR/curl" "$STUB_DIR/ssh"
PATH="$STUB_DIR:$PATH"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"

check_stamp() { # label, expected-mode
    if grep -q "vauchi_push_transport{mode=\"$2\"} 1" "$CAPTURE"; then
        echo "  PASS: $1"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $1 — payload was: $(cat "$CAPTURE")"
        FAIL=$(( FAIL + 1 ))
    fi
}

PUSHGATEWAY_URL="http://stub" PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
check_stamp "direct push is stamped mode=direct" "direct"

PUSHGATEWAY_URL="" PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
check_stamp "full-key push is stamped mode=full" "full"

PUSHGATEWAY_URL="" PUSHGATEWAY_SSH_MODE="restricted" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
check_stamp "restricted-key push is stamped mode=restricted" "restricted"

# The original payload must survive the stamping.
if grep -q '^vauchi_x 1$' "$CAPTURE"; then
    echo "  PASS: the caller's metrics are preserved alongside the stamp"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: stamping dropped the caller's metrics"
    FAIL=$(( FAIL + 1 ))
fi

# Prove it can fail: every transport rejects, so nothing is delivered and
# the helper says so instead of returning success.
if STUB_SSH_RC=1 STUB_CURL_RC=1 PUSHGATEWAY_URL="http://stub" \
    PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>"$STUB_DIR/err"; then
    echo "  FAIL: all transports failed but push returned success"
    FAIL=$(( FAIL + 1 ))
elif grep -q "NO transport delivered" "$STUB_DIR/err"; then
    echo "  PASS: total delivery failure returns nonzero and is reported"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: returned nonzero but did not report why"
    FAIL=$(( FAIL + 1 ))
fi

# A refusal names the key that was tried and keeps what ssh answered. Core's
# binary-size push failed on every sampled main pipeline from 2026-08-20 to
# 2026-10-01 and the log said only "NO transport delivered" (private#15).
STUB_SSH_RC=255 STUB_SSH_ERR="Permission denied (publickey)." PUSHGATEWAY_URL="" \
    PUSHGATEWAY_SSH_MODE="restricted" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>"$STUB_DIR/err" || true
assert_file_contains "a refused push keeps ssh's own message" \
    "$STUB_DIR/err" "Permission denied (publickey)"
assert_file_contains "a refused push names the transport it tried" \
    "$STUB_DIR/err" "NO transport delivered the metric (tried: restricted)"

STUB_CURL_RC=1 PUSHGATEWAY_URL="http://stub" PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>"$STUB_DIR/err" || true
assert_file_contains "with no key decoded, only the direct URL is named" \
    "$STUB_DIR/err" "NO transport delivered the metric (tried: direct)"

# A rejected payload is not a delivery, and the log keeps the Pushgateway's
# reason. The engineering payload was answered HTTP 400 on every sampled day
# from 2026-05-20 to 2026-10-01; curl --fail threw the explanation away and
# exited 22, so nobody could say which line was wrong (private#470).
REJECTION="text format parsing error in line 3: second TYPE line for metric"
if STUB_SSH_STATUS=400 STUB_SSH_ERR="$REJECTION" PUSHGATEWAY_URL="" \
    PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err"; then
    echo "  FAIL: an HTTP 400 over the deploy key was reported as delivered"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: an HTTP 400 over the deploy key is not a delivery"
    PASS=$(( PASS + 1 ))
fi
assert_file_contains "a rejection keeps the Pushgateway's reason" \
    "$STUB_DIR/err" "second TYPE line for metric"
assert_file_contains "a rejection names its status and transport" \
    "$STUB_DIR/err" "pushgateway: HTTP 400 via full"

if STUB_CURL_STATUS=401 STUB_CURL_BODY="unauthorized" PUSHGATEWAY_URL="http://stub" \
    PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err"; then
    echo "  FAIL: an HTTP 401 on the direct URL was reported as delivered"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: an HTTP 401 on the direct URL is not a delivery"
    PASS=$(( PASS + 1 ))
fi
assert_file_contains "a direct rejection names its status" \
    "$STUB_DIR/err" "pushgateway: HTTP 401 via direct"
assert_file_contains "a direct rejection keeps the response body" \
    "$STUB_DIR/err" "unauthorized"

# curl can exit non-zero after the answer arrived (exit 18 when the server
# closes early, as the Pushgateway did while answering 400 in scripts job
# 16885785551). The status it printed still decides; "unreachable" is for
# no answer at all.
STUB_SSH_STATUS=400 STUB_SSH_RC=18 PUSHGATEWAY_URL="" PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err" || true
assert_file_contains "a status that arrived is reported even if curl exits non-zero" \
    "$STUB_DIR/err" "pushgateway: HTTP 400 via full"
STUB_SSH_STATUS=000 STUB_SSH_RC=28 PUSHGATEWAY_URL="" PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err" || true
assert_file_contains "no answer at all is unreachable" \
    "$STUB_DIR/err" "pushgateway: unreachable via full (exit 28)"

# push.vauchi.app wants "Authorization: Bearer <token>" (private#470). The
# token reaches curl through a config on a file descriptor, never the
# command line: on a shared shell runner every job can read the others'
# argv, and this token is what lets a job write metrics.
TOKEN="5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"
PUSHGATEWAY_TOKEN="$TOKEN" PUSHGATEWAY_URL="http://stub" PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
assert_file_contains "the direct push sends the token as a bearer header" \
    "$CAPTURE.config" "Authorization: Bearer $TOKEN"
assert_eq "the token is not on curl's command line" "0" \
    "$(grep -c -F "$TOKEN" "$CAPTURE.argv")"
check_stamp "a push with a token is still stamped mode=direct" "direct"

PUSHGATEWAY_TOKEN="" PUSHGATEWAY_URL="http://stub" PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
assert_eq "without a token no header is sent" "0" \
    "$(grep -c "Authorization" "$CAPTURE.config")"

# 401, 403 and 405 are the endpoint's refusals; each is reported with its
# status and none counts as a delivery.
for refusal in 401 403 405; do
    if STUB_CURL_STATUS=$refusal PUSHGATEWAY_TOKEN="$TOKEN" PUSHGATEWAY_URL="http://stub" \
        PUSHGATEWAY_SSH_MODE="" \
        pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err"; then
        echo "  FAIL: an HTTP $refusal from the endpoint was reported as delivered"
        FAIL=$(( FAIL + 1 ))
    else
        assert_file_contains "an HTTP $refusal from the endpoint is reported" \
            "$STUB_DIR/err" "pushgateway: HTTP $refusal via direct"
    fi
done

# A token that would break out of curl's config line is not sent at all.
: > "$CAPTURE.config"
PUSHGATEWAY_TOKEN='abc" --output "/tmp/x' PUSHGATEWAY_URL="http://stub" PUSHGATEWAY_SSH_MODE="" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err" || true
assert_eq "a malformed token is never written into curl's config" "0" \
    "$(grep -c "output" "$CAPTURE.config")"
assert_file_contains "a malformed token is named, not printed" \
    "$STUB_DIR/err" "PUSHGATEWAY_TOKEN holds characters outside"
assert_eq "…and its value stays out of the log" "0" "$(grep -c "tmp/x" "$STUB_DIR/err")"

# The status must not leak into the job's stdout, where callers read results.
out=$(PUSHGATEWAY_URL="" PUSHGATEWAY_SSH_MODE="full" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null)
assert_eq "a delivery prints nothing on stdout" "" "$out"

rm -rf "$STUB_DIR"
teardown_test

# ── Summary ──────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    exit 0
fi
