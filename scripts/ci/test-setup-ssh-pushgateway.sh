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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ORIG_HOME="$HOME"

# ── Helpers ──────────────────────────────────────────────────────

setup_test() {
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    # Clear any leftover function definition from previous source
    unset -f setup_ssh_pushgateway 2>/dev/null || true
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
    # macOS stat vs Linux stat
    actual_mode=$(stat -f "%Lp" "$path" 2>/dev/null || stat -c "%a" "$path" 2>/dev/null)
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

# Stubs record stdin instead of reaching the network.
cat >"$STUB_DIR/curl" <<STUB
#!/bin/sh
cat > "$CAPTURE"
exit \${STUB_CURL_RC:-0}
STUB
cat >"$STUB_DIR/ssh" <<STUB
#!/bin/sh
cat > "$CAPTURE"
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
