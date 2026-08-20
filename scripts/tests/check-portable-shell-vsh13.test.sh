#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for VSH13 in hooks/check-portable-shell.sh — a web call
# whose HTTP status is discarded.
#
# The motivating case spans continuation lines, so the "fires on a
# multi-line command substitution" case is the one that matters: a
# line-based check passes it silently, which is how every github-mirror
# job in the workspace failed on 2026-08-20 reporting only "exit code 22".
# Rule page: _private/docs/lint-errors/vsh13-web-call-status-discarded.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$SCRIPT_DIR/hooks/check-portable-shell.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

# $1=script content → echoes the number of VSH13 hits
vsh13_hits() {
    d="$(mktemp -d)"
    f="$d/x.sh"
    printf '%s\n' "$1" > "$f"
    n="$("$SCRIPT" "$f" 2>&1 | grep -c 'VSH13' || true)"
    rm -rf "$d"
    printf '%s' "$n"
}

# The exact shape that failed in production: curl -sf piped to jq inside a
# command substitution, split across continuation lines.
MULTILINE='#!/bin/sh
TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer ${JWT}" \
  "https://api.github.com/app/installations/${ID}/access_tokens" \
  | jq -r ".token")
echo "$TOKEN"'

# The replacement: status captured with -w, then branched on.
CAPTURED='#!/bin/sh
: > /tmp/resp.json
HTTP_STATUS=$(curl -s -o /tmp/resp.json -w "%{http_code}" -X POST \
  "https://api.github.com/thing") || HTTP_STATUS="000"
[ "$HTTP_STATUS" = "201" ] || { echo "failed: $HTTP_STATUS"; exit 1; }
TOKEN=$(jq -r ".token" < /tmp/resp.json)
echo "${#TOKEN}"'

SINGLE_LINE='#!/bin/sh
VERSION=$(curl -s https://example.com/v | jq -r .tag)
echo "$VERSION"'

SUPPRESSED='#!/bin/sh
X=$(curl -s https://example.com/x | head -1) # portable-shell-ok: advisory only
echo "$X"'

FAIL_WITH_BODY='#!/bin/sh
X=$(curl --fail-with-body -s https://example.com/x | jq -r .v)
echo "$X"'

# curl not in a substitution and not piped — status reaches the shell.
DIRECT='#!/bin/sh
curl -sf -o /tmp/out https://example.com/x
echo done'

WGET='#!/bin/sh
V=$(wget -q -O - https://example.com/v | head -1)
echo "$V"'

# A comment mentioning the pattern must not trip the rule.
COMMENT_ONLY='#!/bin/sh
# do not write X=$(curl -s url | jq .) — the status is lost
echo ok'

assert_eq "fires on the multi-line production shape" "1" "$(vsh13_hits "$MULTILINE")"
assert_eq "silent once the status is captured"       "0" "$(vsh13_hits "$CAPTURED")"
assert_eq "fires on the single-line shape"           "1" "$(vsh13_hits "$SINGLE_LINE")"
assert_eq "respects portable-shell-ok"               "0" "$(vsh13_hits "$SUPPRESSED")"
assert_eq "accepts --fail-with-body"                 "0" "$(vsh13_hits "$FAIL_WITH_BODY")"
assert_eq "ignores curl whose status reaches sh"     "0" "$(vsh13_hits "$DIRECT")"
assert_eq "fires on wget too"                        "1" "$(vsh13_hits "$WGET")"
assert_eq "ignores a comment describing the pattern" "0" "$(vsh13_hits "$COMMENT_ONLY")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
