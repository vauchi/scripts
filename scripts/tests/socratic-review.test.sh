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
# Stubs mirror the real contracts: `codex exec -o <file> <prompt>` writes
# its answer to the -o file, `kimi -p <prompt>` writes to stdout.
# The codex stub accepts the prompt on stdin when the positional argument
# is `-`, mirroring `codex exec`'s documented behaviour. That path is not a
# nicety: a single argv entry is capped at MAX_ARG_STRLEN (32 * PAGE_SIZE =
# 131072 bytes on Linux), so passing a large brief as an argument fails with
# "Argument list too long" instead of being reviewed.
cat > "$WORK/bin/codex" <<EOF
#!/bin/sh
outfile=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then outfile="\$a"; fi
    prev="\$a"
    last="\$a"
done
if [ "\$last" = "-" ]; then
    cat > "$WORK/codex.prompt"
else
    printf '%s' "\$last" > "$WORK/codex.prompt"
fi
echo "1. codex question?" > "\$outfile"
EOF
cat > "$WORK/bin/kimi" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
printf '%s' "\$last" > "$WORK/kimi.prompt"
echo "1. kimi question?"
EOF
chmod +x "$WORK/bin/codex" "$WORK/bin/kimi"

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

# --- truncation of a diff larger than the 64K pipe buffer --------------
# The small-diff case above cannot catch SIGPIPE: it fits the pipe buffer,
# so the writer finishes before the reader exits. Only a diff past 64K
# exercises the abort that `pipefail` turns a closed pipe into.
git -C "$WORK/repo" checkout -q feature/x
awk 'BEGIN { for (i = 0; i < 20000; i++) print "padding line " i }' \
    > "$WORK/repo/big.txt"
git -C "$WORK/repo" add big.txt
git -C "$WORK/repo" commit -q -m "feat: add a diff larger than the pipe buffer"
run() { out="$(PATH="$WORK/bin:$PATH" SOCRATIC_MAX_DIFF_BYTES=100000 "$SCRIPT" "$@" 2>&1)"; rc=$?; }
run "$WORK/repo"
assert_eq "big diff truncation: exit 0 (not SIGPIPE)" "0" "$rc"
assert_eq "big diff truncation: reviewers still ran" "1" \
    "$(printf '%s' "$out" | grep -qF '1. codex question?' && echo 1 || echo 0)"

# --- a nonsensical cap is refused, not silently applied ----------------
run() { out="$(PATH="$WORK/bin:$PATH" SOCRATIC_MAX_DIFF_BYTES="$1" "$SCRIPT" "$2" 2>&1)"; rc=$?; }
run 0 "$WORK/repo"
assert_eq "zero cap: exit 2" "2" "$rc"
run abc "$WORK/repo"
assert_eq "non-numeric cap: exit 2" "2" "$rc"

# --- the invoker must not silently review its own work -----------------
run() { out="$(PATH="$WORK/bin:$PATH" VAUCHI_AGENT="$1" "$SCRIPT" "$2" "$3" 2>&1)"; rc=$?; }
run kimi "$WORK/repo" both
assert_eq "self-review: warns the invoker is a reviewer" "1" \
    "$(printf '%s' "$out" | grep -qF "invoker 'kimi' is also a reviewer" && echo 1 || echo 0)"
assert_eq "self-review: names the independent alternative" "1" \
    "$(printf '%s' "$out" | grep -qF 'socratic-review <repo> codex' && echo 1 || echo 0)"
run claude "$WORK/repo" both
assert_eq "claude invoker: no warning" "0" \
    "$(printf '%s' "$out" | grep -qF 'is also a reviewer' && echo 1 || echo 0)"

# --- a brief larger than one argv entry may hold ----------------------
# Regression for the 2026-08-04 failure: a 131205-byte diff aborted with
# "/usr/bin/timeout: Argument list too long". Linux caps a SINGLE argv
# string at MAX_ARG_STRLEN (32 * PAGE_SIZE = 131072), independently of the
# far larger ARG_MAX, and the default cap of 200000 sat above that ceiling —
# so the failure was reachable by default, and the script's own advice
# ("Raise SOCRATIC_MAX_DIFF_BYTES") made it worse.
#
# codex reads the prompt from stdin, so it must survive any size under the
# cap. kimi's `-p` takes an argument and has no stdin mode, so the script
# must clamp for it rather than crash.
printf 'padding line to push this diff past the argv ceiling\n' > "$WORK/pad"
i=0
: > "$WORK/repo/big.txt"
while [ "$i" -lt 3000 ]; do
    cat "$WORK/pad" >> "$WORK/repo/big.txt"
    i=$((i + 1))
done
git -C "$WORK/repo" add big.txt
git -C "$WORK/repo" commit -q -m "test: add a diff larger than one argv entry"

big_bytes=$(git -C "$WORK/repo" diff origin/main...HEAD | wc -c | tr -d ' ')
assert_eq "fixture exceeds the argv ceiling" "1" \
    "$([ "$big_bytes" -gt 131072 ] && echo 1 || echo 0)"

run() { out="$(PATH="$WORK/bin:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?; }

run "$WORK/repo" codex
assert_eq "oversize brief: codex still succeeds" "0" "$rc"
assert_eq "oversize brief: codex received the whole diff" "1" \
    "$(grep -qF 'padding line to push this diff past the argv ceiling' \
        "$WORK/codex.prompt" && echo 1 || echo 0)"
assert_eq "oversize brief: codex was not truncated" "0" \
    "$(printf '%s' "$out" | grep -qF 'reviewers saw only the first' && echo 1 || echo 0)"

run "$WORK/repo" kimi
assert_eq "oversize brief: kimi still succeeds" "0" "$rc"
assert_eq "oversize brief: kimi brief fits one argv entry" "1" \
    "$([ "$(wc -c < "$WORK/kimi.prompt" | tr -d ' ')" -lt 131072 ] && echo 1 || echo 0)"
assert_eq "oversize brief: clamp is announced" "1" \
    "$(printf '%s' "$out" | grep -qF 'reviewers saw only the first' && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
