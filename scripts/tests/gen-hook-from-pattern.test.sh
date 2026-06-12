#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for gen-hook-from-pattern.sh.
# The excessive-reread / excessive-reedit template branches were
# retired 2026-06-12 (problem record
# 2026-04-20-excessive-reedit-reread-pattern, findings F1-F6): both
# categories are enforced by hand-maintained session-scoped hooks,
# and the templates embedded the superseded design. The generator
# must refuse them — explicitly and via auto-pick — instead of
# re-emitting the stale hook.
#
# The script derives WORKSPACE_ROOT from its own location, so each
# case copies it into a temp workspace-root layout for hermeticity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../gen-hook-from-pattern.sh"

pass=0
fail=0

assert_exit() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — want exit %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — missing: %s\n' "$name" "$needle" >&2
        fail=$((fail + 1))
    fi
}

mk_workspace() {
    local root="$1"
    mkdir -p "$root/scripts/scripts" "$root/.claude/hooks"
    cp "$SCRIPT" "$root/scripts/scripts/gen-hook-from-pattern.sh"
}

# 1. Explicit retired category — refused with pointer, no file emitted.
for category in excessive-reread excessive-reedit; do
    tmp="$(mktemp -d)"
    mk_workspace "$tmp"
    printf '{"category":"%s"}\n' "$category" > "$tmp/.claude/.session-errors"
    set +e
    out=$(bash "$tmp/scripts/scripts/gen-hook-from-pattern.sh" "$category" 2>&1)
    rc=$?
    set -e
    assert_exit "$category refused" 1 "$rc"
    assert_contains "$category points at shipped hook" "pretool-" "$out"
    assert_contains "$category names the record" "2026-04-20-excessive-reedit-reread-pattern" "$out"
    assert_exit "$category emits no hook file" 1 \
        "$([[ -f "$tmp/.claude/hooks/pretool-$category.sh" ]] && echo 0 || echo 1)"
    rm -rf "$tmp"
done

# 2. Auto-pick landing on a retired category — refused, not templated.
tmp="$(mktemp -d)"
mk_workspace "$tmp"
for _ in 1 2 3; do
    printf '{"category":"excessive-reread"}\n' >> "$tmp/.claude/.session-errors"
done
set +e
out=$(bash "$tmp/scripts/scripts/gen-hook-from-pattern.sh" 2>&1)
rc=$?
set -e
assert_exit "auto-picked retired category refused" 1 "$rc"
assert_contains "auto-pick message points at shipped hook" "pretool-" "$out"
rm -rf "$tmp"

# 3. Unknown category — still the add-a-branch guidance.
tmp="$(mktemp -d)"
mk_workspace "$tmp"
printf '{"category":"some-new-pattern"}\n' > "$tmp/.claude/.session-errors"
set +e
out=$(bash "$tmp/scripts/scripts/gen-hook-from-pattern.sh" some-new-pattern 2>&1)
rc=$?
set -e
assert_exit "unknown category exits 1" 1 "$rc"
assert_contains "unknown category asks for a case branch" "add a case branch" "$out"
rm -rf "$tmp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
