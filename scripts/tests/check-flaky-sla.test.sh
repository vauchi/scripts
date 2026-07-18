#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-flaky-sla.sh — VFL01: FLAKY quarantines
# must carry an issue URL and not exceed the 48h fix-or-delete SLA.
# Rule page: _private/docs/lint-errors/vfl01-flaky-sla.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-flaky-sla.sh"

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
has() { printf '%s' "$2" | grep -q "$1" && echo 1 || echo 0; }

BASE=1700000000

# Build a git repo whose src/lib.rs contains $marker, committed at $epoch.
make_repo() {
    root="$1"; marker="$2"; epoch="${3:-$BASE}"
    git -C "$root" init -q
    git -C "$root" config user.email t@t.t
    git -C "$root" config user.name t
    mkdir -p "$root/src"
    cat > "$root/src/lib.rs" <<RS
#[cfg(test)]
mod tests {
    $marker
    #[test]
    fn flaky_one() { assert_eq!(1, 1); }
}
RS
    git -C "$root" add -A
    GIT_AUTHOR_DATE="@$epoch" GIT_COMMITTER_DATE="@$epoch" \
        git -C "$root" commit -qm init
}
run() { out="$("$SCRIPT" "$1" "$2" "$3" 2>&1)"; rc=$?; }

URL='#[ignore = "FLAKY: https://gitlab.com/vauchi/core/-/issues/1"]'
NOURL='#[ignore = "FLAKY: pending triage"]'

# ── quarantine within SLA (10h old), has URL: exit 0 ──────────────────
F="$(mktemp -d)"; make_repo "$F" "$URL" "$BASE"
run "$F" 48 $((BASE + 10 * 3600))
assert_eq "within SLA: exit 0" "0" "$rc"
rm -rf "$F"

# ── quarantine past SLA (100h old): exit 1 ────────────────────────────
F="$(mktemp -d)"; make_repo "$F" "$URL" "$BASE"
run "$F" 48 $((BASE + 100 * 3600))
assert_eq "past SLA: exit 1" "1" "$rc"
assert_eq "past SLA: VFL01" "1" "$(has VFL01 "$out")"
assert_eq "past SLA: mentions SLA" "1" "$(has 'SLA' "$out")"
rm -rf "$F"

# ── marker missing the mandatory issue URL: exit 1 ────────────────────
F="$(mktemp -d)"; make_repo "$F" "$NOURL" "$BASE"
run "$F" 48 $((BASE + 1 * 3600))
assert_eq "no URL: exit 1" "1" "$rc"
assert_eq "no URL: mentions tracking issue URL" "1" "$(has 'tracking issue URL' "$out")"
rm -rf "$F"

# ── no FLAKY quarantines at all: exit 0 ───────────────────────────────
F="$(mktemp -d)"; make_repo "$F" "// no quarantine here" "$BASE"
run "$F" 48 $((BASE + 999 * 3600))
assert_eq "none: exit 0" "0" "$rc"
rm -rf "$F"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
