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

# ── fix with an Evidence trailer that names the after-state → accepted ─
run_case 'fix: correct relay backoff

Evidence: before: 502 on `just deploy-check`; after: 200 on the same command' relay/src/backoff.rs
assert_eq "fix with Evidence after-state: exit 0" "0" "$rc"

# The after-state may sit on a continuation line of the trailer.
run_case 'fix: describe the window content view

Evidence: job 16461108863 put an identifier on the flagged element;
after: job 16461155146, container issue absent, 6/7 tests pass' macos/Vauchi/Window.swift
assert_eq "fix with after-state on continuation line: exit 0" "0" "$rc"

# ── Evidence that cites only the failure → rejected ───────────────────
# macos 067c6d8 (2026-09-11) passed the old length check with this exact
# trailer; both jobs are pre-fix observations and the fix was wrong.
run_case "fix: stop the window's measuring wrapper from being an a11y element

Evidence: macos job 16439004828 (element tree), 16438937323 (audit issue)." macos/Vauchi/PresentationHostView.swift
assert_eq "fix citing only the failure: exit 1" "1" "$rc"
assert_eq "fix citing only the failure: asks for after:" "1" \
    "$(printf '%s' "$out" | grep -q "VGT11: .*after:" && echo 1 || echo 0)"
assert_eq "fix citing only the failure: offers diag:" "1" \
    "$(printf '%s' "$out" | grep -q "diag:" && echo 1 || echo 0)"

# ── an after-state written as a prediction is a hypothesis → rejected ─
run_case 'fix: bundle the App SDK runtime

Evidence: before: DllNotFoundException in job 16457652091; after: should pass once CI runs' windows/Vauchi.csproj
assert_eq "fix with predicted after-state: exit 1" "1" "$rc"

run_case 'fix: bundle the App SDK runtime

Evidence: before: DllNotFoundException in job 16457652091; after: not yet observed' windows/Vauchi.csproj
assert_eq "fix with unobserved after-state: exit 1" "1" "$rc"

# ── a quoted tool message is an observation, whatever words it holds ──
# YAML's own error reads "did not find expected ','" (#783).
run_case 'fix: quote the cache key

Evidence: before: lint ok; after: the hook printed "did not find expected '"','"' or '"']'"'" and exit 1' scripts/hooks/pre-push
assert_eq "after quoting 'expected' in double quotes: exit 0" "0" "$rc"

run_case 'fix: quote the cache key

Evidence: before: lint ok; after: the job log reads `Job would be retried: no` at line 40' scripts/hooks/pre-push
assert_eq "after quoting 'would' in backticks: exit 0" "0" "$rc"

run_case 'fix: quote the cache key

Evidence: before: lint ok; after: the hook printed '"'expected one of: a, b'"' and exit 1' scripts/hooks/pre-push
assert_eq "after quoting 'expected' in single quotes: exit 0" "0" "$rc"

# A prediction outside the quotes is still a prediction.
run_case 'fix: quote the cache key

Evidence: before: lint ok; after: printed "lint ok" and should pass in CI' scripts/hooks/pre-push
assert_eq "prediction beside a quote: exit 1" "1" "$rc"

# Apostrophes are not quotes: the words between two of them still count.
run_case 'fix: quote the cache key

Evidence: before: lint ok; after: main'"'"'s hook will pass now that it'"'"'s quoted' scripts/hooks/pre-push
assert_eq "prediction between apostrophes: exit 1" "1" "$rc"

# An after: outside the Evidence trailer does not count.
run_case 'fix: bundle the App SDK runtime

after: this line is prose, not the trailer

Evidence: DllNotFoundException in windows job 16457652091' windows/Vauchi.csproj
assert_eq "after: outside the trailer: exit 1" "1" "$rc"

# ── diag: is the honest type for a change pushed to observe its effect ─
run_case 'diag: bundle the App SDK runtime to test the DllNotFound theory' windows/Vauchi.csproj
assert_eq "diag without evidence: exit 0" "0" "$rc"

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
