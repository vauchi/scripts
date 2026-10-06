#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Tests for pushgateway-push.sh, the metrics push helper. It pushes only to
# push.vauchi.app over HTTPS; the ssh transports it used to fall back to are
# gone (private#470).
#
# Run: bash scripts/tests/pushgateway-push.test.sh
# All assertions use plain bash — no external test framework needed.

set -euo pipefail

set -uo pipefail
# Note: not using -e because we need to track pass/fail counts and
# (( 0 )) returns exit code 1 which would abort the script.

# Lives in scripts/tests/ because that is what CI globs
# (.gitlab-ci.yml runs `scripts/tests/*.test.sh`).
SCRIPT_DIR="$(cd "$(dirname "$0")/../ci" && pwd)"
PASS=0
FAIL=0
ORIG_HOME="$HOME"

# ── Helpers ──────────────────────────────────────────────────────

setup_test() {
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    # Clear any leftover function definition from previous source
    unset -f pushgateway_push 2>/dev/null || true

    # Isolate from ambient CI variables; each test exports what it needs.
    # The key variables stay unset too: with any of them present, the
    # helper must still never reach for ssh.
    unset PUSHGATEWAY_URL PUSHGATEWAY_TOKEN
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

# ── Tests ────────────────────────────────────────────────────────

# ── The push (CC-27: prove each refusal can fail) ─────────────────

setup_test "push"
STUB_DIR=$(mktemp -d)
CAPTURE="$STUB_DIR/payload"

# Stubs record stdin instead of reaching the network. Like curl with
# -o /dev/stderr -w '%{http_code}', curl answers with a body on stderr and
# the HTTP status on stdout. ssh only records that it was called: the
# helper must never call it.
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
: > "$STUB_DIR/ssh-called"
exit 255
STUB
chmod +x "$STUB_DIR/curl" "$STUB_DIR/ssh"
PATH="$STUB_DIR:$PATH"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/pushgateway-push.sh"

check_stamp() { # label, expected-mode
    if grep -q "vauchi_push_transport{mode=\"$2\"} 1" "$CAPTURE"; then
        echo "  PASS: $1"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $1 — payload was: $(cat "$CAPTURE")"
        FAIL=$(( FAIL + 1 ))
    fi
}

PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
check_stamp "a push is stamped mode=direct" "direct"

# The original payload must survive the stamping.
if grep -q '^vauchi_x 1$' "$CAPTURE"; then
    echo "  PASS: the caller's metrics are preserved alongside the stamp"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: stamping dropped the caller's metrics"
    FAIL=$(( FAIL + 1 ))
fi

# No fallback: a failed push is reported and nothing else is tried. The ssh
# fallbacks hid credential failures for days (2026-08-01) and the restricted
# key was refused on every probe run since 2026-09-28 (private#15, #470).
# Every ssh-related variable is set here, as CI used to set them.
if STUB_CURL_RC=7 STUB_CURL_STATUS=000 PUSHGATEWAY_URL="http://stub" \
    DEPLOY_SSH_PRIVATE_KEY=/nonexistent PUSHGATEWAY_SSH_KEY=/nonexistent \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>"$STUB_DIR/err"; then
    echo "  FAIL: an unreachable endpoint was reported as delivered"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: an unreachable endpoint is not a delivery"
    PASS=$(( PASS + 1 ))
fi
assert_file_contains "an unreachable endpoint is reported" \
    "$STUB_DIR/err" "pushgateway: unreachable via direct (exit 7)"
assert_file_contains "a failed push says the metric was not delivered" \
    "$STUB_DIR/err" "pushgateway: the metric was not delivered"
assert_eq "a failed push never falls back to ssh" "no" \
    "$([ -e "$STUB_DIR/ssh-called" ] && echo yes || echo no)"

# Without an endpoint there is nothing to push to, and that is a failure the
# caller sees, not a silent skip.
rm -f "$STUB_DIR/ssh-called"
if PUSHGATEWAY_URL="" pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>"$STUB_DIR/err"; then
    echo "  FAIL: a push with no PUSHGATEWAY_URL was reported as delivered"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: a push with no PUSHGATEWAY_URL is not a delivery"
    PASS=$(( PASS + 1 ))
fi
assert_file_contains "a missing endpoint is named" \
    "$STUB_DIR/err" "pushgateway: PUSHGATEWAY_URL is not set"
assert_eq "a missing endpoint never falls back to ssh" "no" \
    "$([ -e "$STUB_DIR/ssh-called" ] && echo yes || echo no)"

# The helper no longer offers key setup; callers that still call it should
# fail loudly at the tag that removes it, not decode a key.
assert_eq "the helper defines no ssh setup function" "no" \
    "$(declare -F setup_ssh_pushgateway >/dev/null && echo yes || echo no)"

# A rejected payload is not a delivery, and the log keeps the Pushgateway's
# reason. The engineering payload was answered HTTP 400 on every sampled day
# from 2026-05-20 to 2026-10-01; curl --fail threw the explanation away and
# exited 22, so nobody could say which line was wrong (private#470).
if STUB_CURL_STATUS=401 STUB_CURL_BODY="unauthorized" PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err"; then
    echo "  FAIL: an HTTP 401 was reported as delivered"
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: an HTTP 401 is not a delivery"
    PASS=$(( PASS + 1 ))
fi
assert_file_contains "a rejection names its status" \
    "$STUB_DIR/err" "pushgateway: HTTP 401 via direct"
assert_file_contains "a rejection keeps the response body" \
    "$STUB_DIR/err" "unauthorized"

# curl can exit non-zero after the answer arrived (exit 18 when the server
# closes early, as the Pushgateway did while answering 400 in scripts job
# 16885785551). The status it printed still decides; "unreachable" is for
# no answer at all.
STUB_CURL_STATUS=400 STUB_CURL_RC=18 PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err" || true
assert_file_contains "a status that arrived is reported even if curl exits non-zero" \
    "$STUB_DIR/err" "pushgateway: HTTP 400 via direct"

# push.vauchi.app wants "Authorization: Bearer <token>" (private#470). The
# token reaches curl through a config on a file descriptor, never the
# command line: on a shared shell runner every job can read the others'
# argv, and this token is what lets a job write metrics.
TOKEN="5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"
PUSHGATEWAY_TOKEN="$TOKEN" PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
assert_file_contains "the push sends the token as a bearer header" \
    "$CAPTURE.config" "Authorization: Bearer $TOKEN"
assert_eq "the token is not on curl's command line" "0" \
    "$(grep -c -F "$TOKEN" "$CAPTURE.argv")"

PUSHGATEWAY_TOKEN="" PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" 2>/dev/null
assert_eq "without a token no header is sent" "0" \
    "$(grep -c "Authorization" "$CAPTURE.config")"

# 401, 403 and 405 are the endpoint's refusals; each is reported with its
# status and none counts as a delivery.
for refusal in 401 403 405; do
    if STUB_CURL_STATUS=$refusal PUSHGATEWAY_TOKEN="$TOKEN" PUSHGATEWAY_URL="http://stub" \
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
PUSHGATEWAY_TOKEN='abc" --output "/tmp/x' PUSHGATEWAY_URL="http://stub" \
    pushgateway_push "vauchi_x 1" "/metrics/job/t" >/dev/null 2>"$STUB_DIR/err" || true
assert_eq "a malformed token is never written into curl's config" "0" \
    "$(grep -c "output" "$CAPTURE.config")"
assert_file_contains "a malformed token is named, not printed" \
    "$STUB_DIR/err" "PUSHGATEWAY_TOKEN holds characters outside"
assert_eq "…and its value stays out of the log" "0" "$(grep -c "tmp/x" "$STUB_DIR/err")"

# The helper is sourced by jobs whose shell is plain sh (the design-drift
# job runs in alpine before bash is installed), so it must parse there. The
# first version of the bearer header used bash process substitution, which
# dash and ash reject at parse time, before any function is called
# (private#470).
for posix_shell in dash sh; do
    command -v "$posix_shell" >/dev/null 2>&1 || continue
    if "$posix_shell" -n "$SCRIPT_DIR/pushgateway-push.sh" 2>"$STUB_DIR/err"; then
        echo "  PASS: the helper parses under $posix_shell"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: the helper does not parse under $posix_shell — $(head -1 "$STUB_DIR/err")"
        FAIL=$(( FAIL + 1 ))
    fi
done

# The status must not leak into the job's stdout, where callers read results.
out=$(PUSHGATEWAY_URL="http://stub" \
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
