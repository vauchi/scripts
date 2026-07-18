#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-idea-config.sh — VIC01: no tracked
# per-user IDE state, no machine-absolute paths in .idea files.
# Rule page: _private/docs/lint-errors/vic01-idea-config-hygiene.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-idea-config.sh"

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

# A valid git-backed fixture: portable .idea using $PROJECT_DIR$ macros.
make_valid() {
    root="$1"
    git -C "$root" init -q
    git -C "$root" config user.email t@t.t
    git -C "$root" config user.name t
    mkdir -p "$root/.idea/runConfigurations"
    printf '<component><option value="file://$PROJECT_DIR$/relay" /></component>\n' \
        > "$root/.idea/runConfigurations/Run_relay.xml"
    printf '/workspace.xml\n' > "$root/.idea/.gitignore"
    git -C "$root" add .idea/runConfigurations/Run_relay.xml .idea/.gitignore
    git -C "$root" commit -qm init
}
run() { out="$("$SCRIPT" "$1" 2>&1)"; rc=$?; }

# ── valid, portable, no per-user leak: exit 0 ─────────────────────────
F="$(mktemp -d)"; make_valid "$F"
run "$F"
assert_eq "valid: exit 0" "0" "$rc"
rm -rf "$F"

# ── tracked per-user workspace.xml: exit 1 ────────────────────────────
F="$(mktemp -d)"; make_valid "$F"
printf '<x/>\n' > "$F/.idea/workspace.xml"
git -C "$F" add -f .idea/workspace.xml
git -C "$F" commit -qm leak
run "$F"
assert_eq "tracked workspace.xml: exit 1" "1" "$rc"
assert_eq "tracked workspace.xml: VIC01" "1" "$(has VIC01 "$out")"
assert_eq "tracked workspace.xml: names per-user state" "1" "$(has 'per-user IDE state' "$out")"
rm -rf "$F"

# ── machine-absolute path in a .idea file: exit 1 ─────────────────────
F="$(mktemp -d)"; make_valid "$F"
printf '<component><option value="file:///home/alice/x" /></component>\n' \
    > "$F/.idea/runConfigurations/Run_relay.xml"
run "$F"
assert_eq "abs path: exit 1" "1" "$rc"
assert_eq "abs path: mentions machine-absolute path" "1" "$(has 'machine-absolute path' "$out")"
rm -rf "$F"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
