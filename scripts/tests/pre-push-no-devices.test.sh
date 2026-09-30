#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# A push must never drive an attached phone or booted simulator: e2e's
# device tests launch the app with clear state, and pushes from one
# session wiped the Pixel another session had on the exchange rig
# (2026-09-27, 2026-09-30; #396). The hook exports VAUCHI_E2E_NO_DEVICES=1
# before any check runs, unless the caller set it explicitly. Pin that.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/pre-push"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

line_no=$(grep -n '^export VAUCHI_E2E_NO_DEVICES=' "$HOOK" | head -n 1 | cut -d: -f1)
[ -n "$line_no" ] || fail "the hook must export VAUCHI_E2E_NO_DEVICES"
checks_no=$(grep -n '^echo "=== Pre-push checks' "$HOOK" | head -n 1 | cut -d: -f1)
[ -n "$checks_no" ] || fail "could not find where the hook starts its checks"
[ "$line_no" -lt "$checks_no" ] || fail "the export must come before any check runs"

line=$(sed -n "${line_no}p" "$HOOK")
got=$(env -u VAUCHI_E2E_NO_DEVICES bash -c "$line; printf '%s' \"\$VAUCHI_E2E_NO_DEVICES\"")
[ "$got" = 1 ] || fail "unset must default to 1 (devices off), got '$got'"
got=$(VAUCHI_E2E_NO_DEVICES=0 bash -c "$line; printf '%s' \"\$VAUCHI_E2E_NO_DEVICES\"")
[ "$got" = 0 ] || fail "an explicit 0 must be kept so a person can opt back in, got '$got'"

echo "pre-push-no-devices: OK"
