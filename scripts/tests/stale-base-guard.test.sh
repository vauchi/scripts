#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression suite for hooks/lib/stale-base-guard.sh. Proves the two
# safety gates hold (backlog 2026-07-11-prepush-hook-rebases-on-tag-push):
#   - a tag-only push never rebases the working branch;
#   - a dirty working tree is never rebased (no autostash of WIP);
#   - a repository on a merge train is never rebased (the train does it,
#     private#1204);
# while the legitimate behaviour (rebase a behind-main branch push, block
# so the user re-pushes) is preserved. Each case runs the guard against a
# throwaway origin+clone so assertions can actually fail (non-tautological
# per CC-21).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SCRIPT_DIR/../hooks/lib/stale-base-guard.sh"
ZERO=0000000000000000000000000000000000000000

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

# make_world → prints a working-clone path on branch feature/x that is one
# commit behind origin/main, clean tree, rebase.autoStash enabled (so the
# pre-fix guard would autostash + move HEAD — the corruption path).
make_world() {
    root="$(mktemp -d)"
    git init -q --bare "$root/origin.git"
    git clone -q "$root/origin.git" "$root/wc" 2>/dev/null
    (
        cd "$root/wc" || exit 1
        git config user.email t@example.com
        git config user.name tester
        git config rebase.autoStash true
        printf 'c0\n' > f
        git add f
        git commit -qm c0
        git push -q origin HEAD:main
        git checkout -q -b feature/x        # feature sits at c0
        git checkout -q main
        printf 'c1\n' >> f
        git commit -qam c1
        git push -q origin main             # origin/main advances to c1
        git checkout -q feature/x           # feature is now 1 behind
    ) >/dev/null 2>&1
    printf '%s\n' "$root/wc"
}

# run_guard <wc> <stdin-specs> — sets OUT (combined output) and RC.
run_guard() {
    OUT="$(printf '%s\n' "$2" | "$GUARD" "$1" 2>&1)"; RC=$?
}

branch_specs() { printf 'refs/heads/feature/x %s refs/heads/feature/x %s' "$1" "$ZERO"; }
tag_specs()    { printf 'refs/tags/v1 %s refs/tags/v1 %s' "$1" "$ZERO"; }

# ── (a) tag-only push on a behind-main branch must NOT rebase ──────────
wc="$(make_world)"; head="$(git -C "$wc" rev-parse HEAD)"
run_guard "$wc" "$(tag_specs "$head")"
assert_eq "tag-only: proceeds (exit 0)" "0" "$RC"
assert_eq "tag-only: HEAD untouched" "$head" "$(git -C "$wc" rev-parse HEAD)"
rm -rf "$(dirname "$wc")"

# ── (b) branch push on a behind-main branch with a DIRTY tree must NOT
#        rebase (never autostash WIP); it blocks with a clear message ───
wc="$(make_world)"; head="$(git -C "$wc" rev-parse HEAD)"
printf 'uncommitted-wip\n' >> "$wc/f"
run_guard "$wc" "$(branch_specs "$head")"
assert_eq "dirty branch: blocked (exit 1)" "1" "$RC"
assert_eq "dirty branch: HEAD untouched" "$head" "$(git -C "$wc" rev-parse HEAD)"
assert_eq "dirty branch: WIP preserved" "1" \
    "$(grep -c 'uncommitted-wip' "$wc/f")"
assert_eq "dirty branch: message names the dirty tree" "present" \
    "$(printf '%s' "$OUT" | grep -qiE 'dirty|uncommitted' && echo present || echo absent)"
rm -rf "$(dirname "$wc")"

# ── (c) branch push on a behind-main branch with a CLEAN tree rebases
#        and blocks (the preserved legitimate behaviour) ────────────────
wc="$(make_world)"; head="$(git -C "$wc" rev-parse HEAD)"
run_guard "$wc" "$(branch_specs "$head")"
assert_eq "clean branch behind: blocked (exit 1)" "1" "$RC"
assert_eq "clean branch behind: announces rebase" "1" \
    "$(printf '%s' "$OUT" | grep -c 'rebasing')"
assert_eq "clean branch behind: HEAD moved (rebased)" "changed" \
    "$([ "$head" != "$(git -C "$wc" rev-parse HEAD)" ] && echo changed || echo same)"
rm -rf "$(dirname "$wc")"

# ── (d) branch push that is already up to date is a no-op ──────────────
wc="$(make_world)"; git -C "$wc" rebase origin/main -q >/dev/null 2>&1
head="$(git -C "$wc" rev-parse HEAD)"
run_guard "$wc" "$(branch_specs "$head")"
assert_eq "up-to-date branch: proceeds (exit 0)" "0" "$RC"
assert_eq "up-to-date branch: no rebase announced" "0" \
    "$(printf '%s' "$OUT" | grep -c 'rebasing')"
rm -rf "$(dirname "$wc")"

# ── (e) a push while on main is not this guard's concern → proceed ─────
wc="$(make_world)"; git -C "$wc" checkout -q main; head="$(git -C "$wc" rev-parse HEAD)"
run_guard "$wc" "$(branch_specs "$head")"
assert_eq "on main: proceeds (exit 0)" "0" "$RC"
rm -rf "$(dirname "$wc")"

# ── (f) the pushed branch still sits on an old main: the rebase only
#        adds commits beneath the branch's own, so a plain push
#        fast-forwards and force would be needless advice ───────────────
wc="$(make_world)"
git -C "$wc" push -q origin feature/x >/dev/null 2>&1   # remote branch = c0
printf 'c2\n' > "$wc/g"; git -C "$wc" add g; git -C "$wc" commit -qm c2
run_guard "$wc" "$(branch_specs "$(git -C "$wc" rev-parse HEAD)")"
assert_eq "remote branch is an ancestor: advises plain push" "1" \
    "$(printf '%s' "$OUT" | grep -c 'Run: git push$')"
assert_eq "remote branch is an ancestor: no force advice" "0" \
    "$(printf '%s' "$OUT" | grep -c 'force-with-lease')"
rm -rf "$(dirname "$wc")"

# ── (g) the remote branch holds commits the rebase rewrote: only a
#        forced push replaces them ─────────────────────────────────────
wc="$(make_world)"
printf 'c2\n' > "$wc/g"; git -C "$wc" add g; git -C "$wc" commit -qm c2
git -C "$wc" push -q origin feature/x >/dev/null 2>&1   # remote branch = c2
run_guard "$wc" "$(branch_specs "$(git -C "$wc" rev-parse HEAD)")"
assert_eq "remote branch rewritten: advises force-with-lease" "1" \
    "$(printf '%s' "$OUT" | grep -c 'Run: git push --force-with-lease')"
rm -rf "$(dirname "$wc")"

# ── (h) a repository on a merge train is never rebased here: the train
#        rebases the car itself, so the push proceeds as is (#1204) ─────
wc="$(make_world)"; root="$(dirname "$wc")"
mv "$root/origin.git" "$root/core.git"
git -C "$wc" remote set-url origin "$root/core.git"
head="$(git -C "$wc" rev-parse HEAD)"
run_guard "$wc" "$(branch_specs "$head")"
assert_eq "merge-train repo behind: proceeds (exit 0)" "0" "$RC"
assert_eq "merge-train repo behind: HEAD untouched" "$head" "$(git -C "$wc" rev-parse HEAD)"
assert_eq "merge-train repo behind: names the train" "1" \
    "$(printf '%s' "$OUT" | grep -c 'merge train')"
rm -rf "$root"

# ── (i) the train list is the one in the environment when set: with
#        core absent from it, core is rebased like any other repo ────────
wc="$(make_world)"; root="$(dirname "$wc")"
mv "$root/origin.git" "$root/core.git"
git -C "$wc" remote set-url origin "$root/core.git"
head="$(git -C "$wc" rev-parse HEAD)"
OUT="$(printf '%s\n' "$(branch_specs "$head")" | VAUCHI_MERGE_TRAIN_REPOS=private "$GUARD" "$wc" 2>&1)"; RC=$?
assert_eq "core outside the train list: blocked (exit 1)" "1" "$RC"
assert_eq "core outside the train list: rebased" "changed" \
    "$([ "$head" != "$(git -C "$wc" rev-parse HEAD)" ] && echo changed || echo same)"
rm -rf "$root"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
