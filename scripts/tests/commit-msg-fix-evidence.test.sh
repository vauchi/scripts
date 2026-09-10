#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/hooks/commit-msg — VGT11: a `fix:` commit
# that touches code carries evidence — a test file in the same commit or
# an `Evidence:` trailer naming what was observed.
# Rule page: _private/docs/lint-errors/vgt11-fix-evidence.md

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
HOOK="$HOOKS_DIR/commit-msg"

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

# Each case runs the hook inside a throwaway repo with the given paths
# staged, so the hook reads real `git diff --cached` output.
run_case() { # $1=message  $2..=paths to stage → sets rc, out
    msg="$1"; shift
    repo="$(mktemp -d)"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m "chore: root"
    for p in "$@"; do
        mkdir -p "$repo/$(dirname "$p")"
        printf 'x\n' > "$repo/$p"
        git -C "$repo" add "$p"
    done
    printf '%s\n' "$msg" > "$repo/.msg"
    out="$(cd "$repo" && "$HOOK" .msg 2>&1)"; rc=$?
    rm -rf "$repo"
}

# ── fix touching code with no test and no trailer → rejected ──────────
run_case 'fix: correct relay backoff' relay/src/backoff.rs
assert_eq "fix without evidence: exit 1" "1" "$rc"
assert_eq "fix without evidence: VGT11 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'VGT11:' && echo 1 || echo 0)"
assert_eq "fix without evidence: names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VGT11: .+ — fix: .+' && echo 1 || echo 0)"
assert_eq "fix without evidence: cites the page" "1" \
    "$(printf '%s' "$out" | grep -q 'lint-errors/vgt11-fix-evidence.md' && echo 1 || echo 0)"

# ── fix with a test file in the same commit → accepted ────────────────
run_case 'fix: correct relay backoff' relay/src/backoff.rs relay/tests/backoff.rs
assert_eq "fix with tests/ path: exit 0" "0" "$rc"

run_case 'fix: harden the vet guard' scripts/check-vet.sh scripts/tests/check-vet.test.sh
assert_eq "fix with .test.sh: exit 0" "0" "$rc"

run_case 'fix: keep toggles addressable' ios/Vauchi/Views/Toggle.swift ios/VauchiTests/ToggleTests.swift
assert_eq "fix with *Tests/ dir: exit 0" "0" "$rc"

run_case 'fix: keep back stack' android/app/src/main/Nav.kt android/app/src/test/NavTest.kt
assert_eq "fix with src/test/: exit 0" "0" "$rc"

# ── fix with an Evidence trailer → accepted ───────────────────────────
run_case 'fix: correct relay backoff

Evidence: observed 502 on `just deploy-check` before, 200 after' relay/src/backoff.rs
assert_eq "fix with Evidence trailer: exit 0" "0" "$rc"

# ── trailer too short to name an observation → rejected ───────────────
run_case 'fix: correct relay backoff

Evidence: works' relay/src/backoff.rs
assert_eq "fix with vacuous trailer: exit 1" "1" "$rc"

# ── docs-only fix needs no evidence ───────────────────────────────────
run_case 'fix: repair broken link' docs/src/guide.md README.md
assert_eq "docs-only fix: exit 0" "0" "$rc"

# ── other types are untouched by VGT11 ────────────────────────────────
run_case 'feat: add relay backoff' relay/src/backoff.rs
assert_eq "feat without test: exit 0 (VGT11 is fix-only)" "0" "$rc"

run_case 'tidy: rename backoff helper' relay/src/backoff.rs
assert_eq "tidy: exit 0" "0" "$rc"

# ── VGT08 still rejects a bad subject first ───────────────────────────
run_case 'Fixed the thing' relay/src/backoff.rs
assert_eq "bad subject: exit 1" "1" "$rc"
assert_eq "bad subject: VGT08 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'VGT08:' && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
