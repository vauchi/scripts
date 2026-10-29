#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/hooks/commit-msg — VGT12: a feat:, fix: or
# refactor: commit that stages a protocol path says what it means for the
# spec, with a `Spec:` trailer.
# Rule page: _private/docs/lint-errors/vgt12-spec-trailer.md
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

# Each case runs the hook inside a throwaway repo named like the real
# one (the hook reads the repository name for the relays), with the
# given paths staged.
run_case() { # $1=repo name  $2=message  $3..=paths to stage → sets rc, out
    name="$1"; msg="$2"; shift 2
    parent="$(mktemp -d)"
    repo="$parent/$name"
    mkdir -p "$repo"
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
    rm -rf "$parent"
}

# ── feat on a Core protocol path without the trailer → rejected ───────
run_case core 'feat: rotate the escrow gate daily' vauchi-core/src/exchange/escrow.rs
assert_eq "feat on exchange/ without Spec: exit 1" "1" "$rc"
assert_eq "feat on exchange/ without Spec: VGT12 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'VGT12:' && echo 1 || echo 0)"
assert_eq "feat on exchange/ without Spec: names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VGT12: .+ — fix: .+' && echo 1 || echo 0)"
assert_eq "feat on exchange/ without Spec: cites the page" "1" \
    "$(printf '%s' "$out" | grep -q 'lint-errors/vgt12-spec-trailer.md' && echo 1 || echo 0)"

# ── the same commit with Spec: unchanged → accepted ───────────────────
run_case core 'feat: rotate the escrow gate daily

Spec: unchanged' vauchi-core/src/exchange/escrow.rs
assert_eq "feat with Spec: unchanged: exit 0" "0" "$rc"

# ── a trailer naming claims or a spec MR → accepted ───────────────────
run_case core 'fix: reject a stale delta below the device floor

Evidence: before: delta applied; after: "stale version" refused in the test
Spec: S2, update-and-sync C4 (spec!20)' vauchi-core/src/sync/card_update.rs vauchi-core/tests/it/sync_tests.rs
assert_eq "fix with Spec: S2 …: exit 0" "0" "$rc"

# ── an empty trailer is not an attestation → rejected ─────────────────
run_case core 'refactor: split the mailbox token module

Spec:' vauchi-core/src/network/mailbox_token.rs
assert_eq "empty Spec: trailer: exit 1" "1" "$rc"

# ── refactor touching the models → needs the trailer ──────────────────
run_case core 'refactor: rename the recovery lemmas' vauchi-core/verification/recovery_acceptance.spthy
assert_eq "refactor on verification/ without Spec: exit 1" "1" "$rc"

# ── vauchi-protocol is a protocol path ────────────────────────────────
run_case core 'feat: add a field to the register request' vauchi-protocol/src/relay.rs
assert_eq "feat on vauchi-protocol/ without Spec: exit 1" "1" "$rc"

# ── a relay's src/ is a protocol path; its tests are not ──────────────
run_case relay 'feat: cap the ticket body' src/handler/register.rs
assert_eq "relay feat on src/ without Spec: exit 1" "1" "$rc"
run_case ohttp-relay 'feat: shorten the delay window' src/delay.rs
assert_eq "ohttp-relay feat on src/ without Spec: exit 1" "1" "$rc"
run_case relay 'test: cover the ticket cap' tests/register.rs
assert_eq "relay test: commit: exit 0" "0" "$rc"

# ── outside the protocol paths, or a non-behaviour type → no trailer ──
run_case core 'feat: new settings toggle' vauchi-app/src/settings.rs
assert_eq "feat on vauchi-app/: exit 0" "0" "$rc"
run_case core 'feat: faster list rendering' vauchi-core/src/api/contacts.rs
assert_eq "feat on api/: exit 0" "0" "$rc"
run_case core 'test: pin the escrow gate derivation' vauchi-core/tests/it/escrow_tests.rs
assert_eq "test: commit on tests/: exit 0" "0" "$rc"
run_case core 'tidy: wrap a long line' vauchi-core/src/exchange/escrow.rs
assert_eq "tidy: on exchange/: exit 0" "0" "$rc"
run_case core 'docs: explain the gate' vauchi-core/src/exchange/README.md
assert_eq "docs under exchange/: exit 0" "0" "$rc"

# ── a repo that is not Core or a relay uses the Core paths only ───────
run_case cli 'feat: print the relay url' src/main.rs
assert_eq "cli feat on src/: exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
