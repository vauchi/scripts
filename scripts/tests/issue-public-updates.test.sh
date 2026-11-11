#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# issue-public-updates.test.sh — every private issue opened through
# `just gitlab issue-create` carries a "Public updates once done and tested"
# section (owner decision 2026-11-11, vauchi/private#1229).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../issue-public-updates.sh"

pass=0
fail=0

check() {
    local name="$1" ok="$2"
    if [ "$ok" = yes ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$name" >&2
        fail=$((fail + 1))
    fi
}

count_heading() {
    printf '%s' "$1" | grep -c '^## Public updates once done and tested$' || true
}

out=$(bash "$SCRIPT" "A body without the section.")
check "a description without the section gets it" "$([ "$(count_heading "$out")" = 1 ] && echo yes || echo no)"
check "the original text is kept first" "$(printf '%s' "$out" | head -1 | grep -qx 'A body without the section.' && echo yes || echo no)"

with=$'Body.\n\n## Public updates once done and tested\n\n- [ ] docs/src/users/faq.md'
out=$(bash "$SCRIPT" "$with")
check "a description that has the section is unchanged" "$([ "$out" = "$with" ] && echo yes || echo no)"

out=$(bash "$SCRIPT" "")
check "an empty description gets the section alone" "$([ "$(count_heading "$out")" = 1 ] && echo yes || echo no)"

if bash "$SCRIPT" >/dev/null 2>&1; then
    check "a missing argument is an error, not a silent default" no
else
    check "a missing argument is an error, not a silent default" yes
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
