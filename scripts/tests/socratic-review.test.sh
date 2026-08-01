#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for socratic-review.sh. Stubs `codex`/`kimi` on PATH so
# the contract is exercised without spending a provider call.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/socratic-review.sh"
WORK="/tmp/socratic-review.test.$$"
trap 'rm -rf "$WORK"' EXIT

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

# --- a throwaway repo with an origin/main and a feature branch ---------
mkdir -p "$WORK/bin" "$WORK/repo"
git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" config user.email t@example.com
git -C "$WORK/repo" config user.name Test
git -C "$WORK/repo" config commit.gpgsign false
printf 'one\n' > "$WORK/repo/a.txt"
git -C "$WORK/repo" add a.txt
git -C "$WORK/repo" commit -q -m "chore: base"
# Fake the remote-tracking ref — no network, no remote needed.
git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD
git -C "$WORK/repo" checkout -q -b feature/x
printf 'two\n' >> "$WORK/repo/a.txt"
git -C "$WORK/repo" add a.txt
git -C "$WORK/repo" commit -q -m "feat: add a second line"

# --- stub reviewers: record the prompt, emit a marker ------------------
for tool in codex kimi; do
    cat > "$WORK/bin/$tool" <<EOF
#!/bin/sh
# codex takes "exec <prompt>", kimi takes "-p <prompt>" — last arg is the brief.
for a in "\$@"; do last="\$a"; done
printf '%s' "\$last" > "$WORK/$tool.prompt"
echo "1. $tool question?"
EOF
    chmod +x "$WORK/bin/$tool"
done

run() { out="$(PATH="$WORK/bin:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?; }

run "$WORK/repo"
assert_eq "both reviewers: exit 0" "0" "$rc"
assert_eq "codex output shown" "1" \
    "$(printf '%s' "$out" | grep -qF '1. codex question?' && echo 1 || echo 0)"
assert_eq "kimi output shown" "1" \
    "$(printf '%s' "$out" | grep -qF '1. kimi question?' && echo 1 || echo 0)"
assert_eq "diff reached the reviewer" "1" \
    "$(grep -qF '+two' "$WORK/codex.prompt" && echo 1 || echo 0)"
assert_eq "commit subjects reached the reviewer" "1" \
    "$(grep -qF 'feat: add a second line' "$WORK/kimi.prompt" && echo 1 || echo 0)"
assert_eq "brief forbids rewriting" "1" \
    "$(grep -qF 'do not rewrite it' "$WORK/codex.prompt" && echo 1 || echo 0)"

run "$WORK/repo" kimi
assert_eq "single reviewer: exit 0" "0" "$rc"
assert_eq "single reviewer skips codex" "0" \
    "$(printf '%s' "$out" | grep -qF '1. codex question?' && echo 1 || echo 0)"

# --- refusals ----------------------------------------------------------
run "$WORK/repo" bogus
assert_eq "unknown reviewer: exit 2" "2" "$rc"

git -C "$WORK/repo" checkout -q main
run "$WORK/repo"
assert_eq "on main: exit 2" "2" "$rc"
assert_eq "on main: says why" "1" \
    "$(printf '%s' "$out" | grep -qF 'nothing to review' && echo 1 || echo 0)"
git -C "$WORK/repo" checkout -q feature/x

run "$WORK/not-a-repo"
assert_eq "non-repo: exit 2" "2" "$rc"

# A missing CLI must fail loud, not silently review with one provider.
run() { out="$(PATH="$WORK/emptybin:/usr/bin:/bin" "$SCRIPT" "$@" 2>&1)"; rc=$?; }
mkdir -p "$WORK/emptybin"
run "$WORK/repo"
assert_eq "missing CLI: exit 1" "1" "$rc"
assert_eq "missing CLI: names the tool" "1" \
    "$(printf '%s' "$out" | grep -qE "'(codex|kimi)' not on PATH" && echo 1 || echo 0)"

# --- truncation is announced, never silent -----------------------------
run() { out="$(PATH="$WORK/bin:$PATH" SOCRATIC_MAX_DIFF_BYTES=50 "$SCRIPT" "$@" 2>&1)"; rc=$?; }
run "$WORK/repo"
assert_eq "truncated: exit 0" "0" "$rc"
assert_eq "truncated: warns the reader" "1" \
    "$(printf '%s' "$out" | grep -qF 'TRUNCATED' && echo 1 || echo 0)"
assert_eq "truncated: tells the reviewer too" "1" \
    "$(grep -qF 'truncated at 50' "$WORK/codex.prompt" && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
