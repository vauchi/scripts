#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-spec-trailer.sh --range: the CI re-check of VGT12 over a merge
# request's commits. It catches what the local hook cannot: a commit made
# with --no-verify, in the web editor or by a tool without the hook.
# Rule page: _private/docs/lint-errors/vgt12-spec-trailer.md
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-spec-trailer.sh"
pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

new_repo() { # $1=name → repo path with a root commit, prints path
    r="$work/$1-$RANDOM"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name t
    git -C "$r" commit -q --allow-empty -m "chore: root"
    printf '%s' "$r"
}

commit_file() { # $1=repo $2=path $3=message
    mkdir -p "$1/$(dirname "$2")"
    printf '%s\n' "$RANDOM" >> "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q --no-verify -m "$3"
}

run_range() { # $1=repo $2=repo-name → rc, out
    base=$(git -C "$1" rev-list --max-parents=0 HEAD)
    out="$(cd "$1" && "$SCRIPT" --range "$base" HEAD "$2" 2>&1)"; rc=$?
}

# ── a behaviour change on a protocol path, hook bypassed → rejected ───
r=$(new_repo core)
commit_file "$r" vauchi-core/src/exchange/escrow.rs 'feat: rotate the escrow gate daily'
run_range "$r" core
assert_eq "feat on exchange/ without Spec: exit 1" "1" "$rc"
assert_eq "feat on exchange/ without Spec: names the rule and the fix" "1" \
    "$(printf '%s' "$out" | grep -cE 'VGT12: .+ — fix: .+')"
assert_eq "feat on exchange/ without Spec: cites the page" "1" \
    "$(printf '%s' "$out" | grep -c 'lint-errors/vgt12-spec-trailer.md')"
assert_eq "feat on exchange/ without Spec: names the commit" "1" \
    "$(printf '%s' "$out" | grep -c 'feat: rotate the escrow gate daily')"
assert_eq "feat on exchange/ without Spec: names the path" "1" \
    "$(printf '%s' "$out" | grep -c 'vauchi-core/src/exchange/escrow.rs')"

# ── the same commit with the trailer → accepted ───────────────────────
r=$(new_repo core)
commit_file "$r" vauchi-core/src/exchange/escrow.rs 'feat: rotate the escrow gate daily

Spec: unchanged'
run_range "$r" core
assert_eq "feat with Spec: unchanged: exit 0" "0" "$rc"

r=$(new_repo core)
commit_file "$r" vauchi-core/src/sync/delta.rs 'fix: reject a stale delta below the device floor

Spec: S2, update-and-sync C3 (spec!9)'
run_range "$r" core
assert_eq "fix with Spec: naming claims: exit 0" "0" "$rc"

# ── a trailer with no value says nothing → rejected ───────────────────
r=$(new_repo core)
commit_file "$r" vauchi-core/src/network/mailbox_token.rs 'refactor: split the mailbox token module

Spec: '
run_range "$r" core
assert_eq "empty Spec: trailer: exit 1" "1" "$rc"

# ── every protocol path of Core and of the relays ─────────────────────
for path in vauchi-core/src/crypto/ratchet.rs vauchi-core/src/backup/mod.rs \
    vauchi-core/src/recovery/mod.rs vauchi-core/verification/card_update.spthy \
    vauchi-protocol/src/relay.rs; do
    r=$(new_repo core)
    commit_file "$r" "$path" 'refactor: move it'
    run_range "$r" core
    assert_eq "core refactor on $path without Spec: exit 1" "1" "$rc"
done
for name in relay ohttp-relay; do
    r=$(new_repo "$name")
    commit_file "$r" src/handler.rs 'feat: cap the body'
    run_range "$r" "$name"
    assert_eq "$name feat on src/ without Spec: exit 1" "1" "$rc"
done

# ── what the rule exempts ─────────────────────────────────────────────
for subject in 'test: pin it' 'tidy: wrap a line' 'docs: explain it' \
    'chore: bump a pin' 'wip: half of it' 'diag: log the branch taken'; do
    r=$(new_repo core)
    commit_file "$r" vauchi-core/src/exchange/escrow.rs "$subject"
    run_range "$r" core
    assert_eq "'$subject' on exchange/: exit 0" "0" "$rc"
done

r=$(new_repo core)
commit_file "$r" vauchi-app/src/settings.rs 'feat: new settings toggle'
commit_file "$r" vauchi-core/src/api/contacts.rs 'feat: faster list rendering'
commit_file "$r" vauchi-core/src/exchange/README.md 'feat: a page beside the code'
run_range "$r" core
assert_eq "feat outside protocol paths, and a .md inside one: exit 0" "0" "$rc"

r=$(new_repo relay)
commit_file "$r" tests/register.rs 'feat: a test helper'
run_range "$r" relay
assert_eq "relay feat outside src/: exit 0" "0" "$rc"

r=$(new_repo cli)
commit_file "$r" src/main.rs 'feat: print the relay url'
run_range "$r" cli
assert_eq "cli feat on src/: exit 0" "0" "$rc"

# ── one bad commit among good ones fails the range, and only it is named
r=$(new_repo core)
commit_file "$r" vauchi-core/src/exchange/escrow.rs 'feat: the good one

Spec: unchanged'
commit_file "$r" vauchi-core/src/exchange/escrow.rs 'fix: the bad one'
commit_file "$r" vauchi-core/tests/it/escrow_tests.rs 'test: after it'
run_range "$r" core
assert_eq "one bad commit among good ones: exit 1" "1" "$rc"
assert_eq "one bad commit among good ones: one violation reported" "1" \
    "$(printf '%s' "$out" | grep -c 'VGT12:')"
assert_eq "one bad commit among good ones: the good one is not named" "0" \
    "$(printf '%s' "$out" | grep -c 'the good one')"

# ── the repository name defaults to the directory name ────────────────
r="$work/relay"
mkdir -p "$r"
git -C "$r" init -q
git -C "$r" config user.email t@example.com
git -C "$r" config user.name t
git -C "$r" commit -q --allow-empty -m "chore: root"
commit_file "$r" src/handler.rs 'feat: cap the body'
base=$(git -C "$r" rev-list --max-parents=0 HEAD)
out="$(cd "$r" && "$SCRIPT" --range "$base" HEAD 2>&1)"; rc=$?
assert_eq "no repo name given, directory is relay: exit 1" "1" "$rc"

# ── a check that cannot read its input does not pass ──────────────────
r=$(new_repo core)
out="$(cd "$r" && "$SCRIPT" --range 0000000000000000000000000000000000000000 HEAD core 2>&1)"; rc=$?
assert_eq "unknown base commit: exit 2, not a pass" "2" "$rc"
out="$(cd "$r" && "$SCRIPT" --range 2>&1)"; rc=$?
assert_eq "--range without a range: exit 2" "2" "$rc"
out="$(cd "$r" && "$SCRIPT" 2>&1)"; rc=$?
assert_eq "no mode: exit 2" "2" "$rc"
out="$(cd "$work" && "$SCRIPT" --staged "$r/.git/HEAD" core 2>&1)"; rc=$?
assert_eq "--staged outside a repository: exit 2, not a pass" "2" "$rc"

# ── --staged: the hook's question, from the index ─────────────────────
r=$(new_repo core)
mkdir -p "$r/vauchi-core/src/exchange"
printf 'x\n' > "$r/vauchi-core/src/exchange/escrow.rs"
git -C "$r" add vauchi-core/src/exchange/escrow.rs
printf 'feat: rotate the escrow gate daily\n' > "$r/.msg"
out="$(cd "$r" && "$SCRIPT" --staged .msg core 2>&1)"; rc=$?
assert_eq "--staged feat on exchange/ without Spec: exit 1" "1" "$rc"
printf 'feat: rotate the escrow gate daily\n\n# Spec: unchanged\n' > "$r/.msg"
out="$(cd "$r" && "$SCRIPT" --staged .msg core 2>&1)"; rc=$?
assert_eq "--staged: a trailer in a comment line does not count: exit 1" "1" "$rc"
printf 'feat: rotate the escrow gate daily\n\nSpec: unchanged\n' > "$r/.msg"
out="$(cd "$r" && "$SCRIPT" --staged .msg core 2>&1)"; rc=$?
assert_eq "--staged with Spec: unchanged: exit 0" "0" "$rc"

echo ""
echo "check-spec-trailer: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
