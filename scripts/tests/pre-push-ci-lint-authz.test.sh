#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# `glab ci lint` POSTs to the project's lint endpoint. A token without
# permission there fails identically to a broken config, and the hook used
# to report both as "CI config is invalid" — so every push to a repo using
# `project:` includes was blocked for a reason unrelated to the config
# (observed on tui, project 77874360).
#
# The hook now classifies the failure. This pins that classification, and
# per CC-27 asserts BOTH directions: an authz failure must not read as a
# config verdict, and a genuine validation error must still fail.
#
# The pattern is read out of the hook so the test tracks the real thing
# rather than a copy that can drift (same approach as
# pre-push-code-classification.test.sh).

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/lib/ci-lint.sh"

pass=0
fail=0

# Pull the classifier regex straight from the hook.
AUTHZ_PATTERN=$(sed -n "s/.*grep -qE '\(invalid_token[^']*\)'.*/\1/p" "$HOOK" | head -1)
if [ -z "$AUTHZ_PATTERN" ]; then
    echo "FAIL: could not read the authz classifier regex from $HOOK" >&2
    exit 1
fi

is_authz() {
    printf '%s' "$1" | grep -qE "$AUTHZ_PATTERN"
}

expect_authz() {
    if is_authz "$2"; then
        printf '  PASS %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  FAIL %s — should classify as auth/permission\n' "$1" >&2
        fail=$((fail + 1))
    fi
}

expect_config_error() {
    if is_authz "$2"; then
        printf '  FAIL %s — must NOT be excused as auth; it is a real config error\n' "$1" >&2
        fail=$((fail + 1))
    else
        printf '  PASS %s\n' "$1"; pass=$((pass + 1))
    fi
}

# ── Auth/permission failures — must not read as a config verdict ──────
expect_authz "403 Forbidden (the tui case)" \
    'Post https://gitlab.com/api/v4/projects/77874360/ci/lint: 403 {message: 403 Forbidden}.'
expect_authz "401 expired token" \
    'GET https://gitlab.com/api/v4/user: 401 {error: invalid_token}, {error_description: Token is expired.}'
expect_authz "insufficient scope" \
    '403 {error: insufficient_scope}'
expect_authz "plain Unauthorized" \
    'Unauthorized'

# ── Genuine validation failures — must still block ────────────────────
expect_config_error "unknown keyword" \
    'jobs:test config contains unknown keys: scripts'
expect_config_error "missing script" \
    'jobs:build config should implement a script: or a trigger: keyword'
expect_config_error "bad include" \
    'Included file `/ci-templates/nope.yml` does not have valid YAML syntax!'
expect_config_error "empty variables body" \
    'jobs:test:unit:variables config should be a hash of key value pairs'

# A validation message that merely mentions a number resembling a status
# code must not be excused — the classifier keys on auth vocabulary, and
# this guards against a regex so loose it swallows real errors.
expect_config_error "message containing 401 as data" \
    'jobs:deploy variables RETRY_AFTER contains invalid value 401x'

# ── The fallback checker the hook calls must exist and be runnable ────
FALLBACK="$DIR/scripts/check-ci-yaml-structure.sh"
if [ -f "$FALLBACK" ] && sh "$FALLBACK" >/dev/null 2>&1; [ $? -eq 2 ]; then
    printf '  PASS fallback structural checker is present and runnable\n'
    pass=$((pass + 1))
else
    printf '  FAIL fallback checker missing or not runnable: %s\n' "$FALLBACK" >&2
    fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
