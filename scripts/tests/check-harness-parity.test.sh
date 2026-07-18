#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-harness-parity.sh — VHC01: harness
# shared trees stay symlinks into _private/.claude, no broken symlinks,
# entry files stay thin pointers to CLAUDE.md.
# Rule page: _private/docs/lint-errors/vhc01-harness-parity.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-harness-parity.sh"

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

# Build a faithful valid workspace fixture: harness dirs are symlinks into
# _private, whose shared trees are ../../.claude symlinks that resolve.
make_valid() {
    root="$1"
    mkdir -p "$root/_private/.claude/rules" "$root/_private/.claude/docs" \
             "$root/_private/.claude/skills"
    ( cd "$root" && ln -s _private/.claude .claude )
    for h in .codex .kimi-code; do
        mkdir -p "$root/_private/$h"
        ( cd "$root/_private/$h" \
            && ln -s ../../.claude/rules rules \
            && ln -s ../../.claude/docs docs \
            && ln -s ../../.claude/skills skills )
        ( cd "$root" && ln -s "_private/$h" "$h" )
    done
    mkdir -p "$root/_private/.junie"
    ( cd "$root" && ln -s _private/.junie .junie )
    printf 'Junie entry — canonical guide is CLAUDE.md\n' > "$root/_private/.junie/AGENTS.md"
    printf 'Kimi entry — see CLAUDE.md\n' > "$root/KIMI.md"
    printf 'Codex entry — see CLAUDE.md\n' > "$root/AGENTS.md"
    printf '# canonical guide\n' > "$root/CLAUDE.md"
}
run() { out="$("$SCRIPT" "$1" 2>&1)"; rc=$?; }

# ── valid workspace: exit 0 ───────────────────────────────────────────
F="$(mktemp -d)"; make_valid "$F"
run "$F"
assert_eq "valid: exit 0" "0" "$rc"
rm -rf "$F"

# ── real dir instead of symlink (duplication reintroduced): exit 1 ────
F="$(mktemp -d)"; make_valid "$F"
rm "$F/_private/.kimi-code/rules"; mkdir "$F/_private/.kimi-code/rules"
run "$F"
assert_eq "real dir: exit 1" "1" "$rc"
assert_eq "real dir: VHC01 in message" "1" "$(has VHC01 "$out")"
assert_eq "real dir: names real directory" "1" "$(has 'real directory' "$out")"
rm -rf "$F"

# ── broken symlink under a harness dir: exit 1 ────────────────────────
F="$(mktemp -d)"; make_valid "$F"
rm "$F/_private/.codex/docs"
( cd "$F/_private/.codex" && ln -s ../../.claude/does-not-exist docs )
run "$F"
assert_eq "broken link: exit 1" "1" "$rc"
assert_eq "broken link: mentions broken symlink" "1" "$(has 'broken symlink' "$out")"
rm -rf "$F"

# ── entry file over the thin budget: exit 1 ───────────────────────────
F="$(mktemp -d)"; make_valid "$F"
{ printf 'CLAUDE.md pointer present\n'; i=0; while [ "$i" -lt 200 ]; do echo "x"; i=$((i+1)); done; } > "$F/KIMI.md"
run "$F"
assert_eq "over budget: exit 1" "1" "$rc"
assert_eq "over budget: mentions budget" "1" "$(has 'thin-entry budget' "$out")"
rm -rf "$F"

# ── entry file missing the CLAUDE.md pointer: exit 1 ──────────────────
F="$(mktemp -d)"; make_valid "$F"
printf 'a standalone entry with no canonical reference\n' > "$F/AGENTS.md"
run "$F"
assert_eq "no pointer: exit 1" "1" "$rc"
assert_eq "no pointer: mentions canonical pointer" "1" "$(has 'canonical pointer' "$out")"
rm -rf "$F"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
