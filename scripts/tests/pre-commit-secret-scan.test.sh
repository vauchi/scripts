#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The secret scan decides what a commit will contain, so it must read the
# STAGED blob. It used to list filenames from the index and then grep the
# working tree, which is a different thing whenever the two disagree — and
# it skipped any path missing from the working tree entirely.
#
# Its fixture exclusion was also an unanchored substring match, so
# `release-latest.md` was skipped because "latest" contains "test".
#
# Per CC-27 this asserts BOTH directions: the scanner must block a staged
# secret however the working tree is arranged, and must still not block on
# the genuine fixtures the exclusion exists for.
#
# Runs the real hook against a throwaway repo. Only text files are staged,
# so the Rust, shell and formatting stages skip and the secrets stage is
# what is under test.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/pre-commit"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

pass=0
fail=0
# Assembled at runtime so this file does not itself carry the literal the
# scanner blocks on. The alternative — exempting this path — is the hole
# that was just removed; a test for a security control must not require
# the control to look away from it.
SECRET="-----BEGIN RSA PRIVAT""E KEY-----"

# stage <path> <content>; then optional working-tree mutation:
#   keep    leave the working tree matching the index
#   scrub   overwrite the working copy with clean content
#   delete  remove the working copy
run_case() {
    label=$1; path=$2; mutation=$3; want=$4   # want: block | allow

    repo=$(mktemp -d)
    git -C "$repo" init --quiet
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name Test

    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$SECRET" > "$repo/$path"
    git -C "$repo" add "$path"

    case "$mutation" in
        scrub)  printf 'nothing to see here\n' > "$repo/$path" ;;
        delete) rm -f "$repo/$path" ;;
    esac

    out=$( (cd "$repo" && bash "$HOOK") 2>&1 )
    code=$?

    blocked=no
    if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'BLOCKING'; then
        blocked=yes
    fi

    got=allow
    [ "$blocked" = yes ] && got=block

    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — wanted %s, got %s\n' "$label" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$repo"
}

echo "== must block: the staged blob carries key material =="
run_case "plain staged secret"                 "config/keys.md"        keep   block
run_case "working tree scrubbed after staging" "config/keys.md"        scrub  block
run_case "working tree deleted after staging"  "config/keys.md"        delete block

echo
echo "== must block: paths that merely contain a fixture word =="
run_case "release-latest.md (contains 'test')" "docs/release-latest.md" keep  block
run_case "protest.md (contains 'test')"        "docs/protest.md"        keep  block
run_case "sampler.md (contains 'sample')"      "docs/sampler.md"        keep  block

echo
echo "== must block: key material, whatever the path is called =="
# A fixture path suppresses the advisory WARNING tier only. It used to
# suppress the blocking tier too, which made the gate opt-out by rename:
# `secrets.env` sails through as `secrets-example.env`. Measured across
# the workspace, that exemption covered 1156 files and shielded exactly
# one piece of blocking-tier material — the sample key in this very test.
run_case "under tests/"                        "tests/fixtures/key.md"  keep  block
run_case "named *-example.*"                   "docs/key-example.md"    keep  block
run_case "under spec/"                         "spec/fixtures/key.md"   keep  block

echo
echo "== the WARNING tier is where a fixture path still suppresses =="
# The exemption's whole justification. Without this half pinned, a later
# change could quietly make it suppress nothing and look correct: 33 files
# across the workspace trip these patterns in fixture paths, and warnings
# on routine commits stop being read.
warn_case() {
    label=$1; path=$2; want=$3   # want: warn | quiet

    repo=$(mktemp -d)
    git -C "$repo" init --quiet
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name Test
    mkdir -p "$repo/$(dirname "$path")"
    printf 'PASSWORD = hunter2\n' > "$repo/$path"
    git -C "$repo" add "$path"
    out=$( (cd "$repo" && bash "$HOOK") 2>&1 )

    got=quiet
    printf '%s' "$out" | grep -q 'WARNING: Potential secret' && got=warn

    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$label"; pass=$((pass + 1))
    else
        printf '  FAIL %s — wanted %s, got %s\n' "$label" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$repo"
}
warn_case "ordinary path warns"        "config/app.md"          warn
warn_case "fixture path stays quiet"   "tests/fixtures/app.md"  quiet
warn_case "*-example.* stays quiet"    "docs/app-example.md"    quiet

echo
echo "== must block: a file that merely mentions the scanner's marker =="
# The self-exemption must key on WHERE the file is, never on what it
# contains. A content trigger is forgeable: anyone can paste the marker
# into a .env and the scan skips the whole file.
decoy=$(mktemp -d)
git -C "$decoy" init --quiet
git -C "$decoy" config user.email t@example.com
git -C "$decoy" config user.name Test
printf '# SECRET_PATTERNS_BLOCKING=(\n%s\n' "$SECRET" > "$decoy/notes.md"
git -C "$decoy" add notes.md
decoy_out=$( (cd "$decoy" && bash "$HOOK") 2>&1 )
if printf '%s' "$decoy_out" | grep -q 'BLOCKING'; then
    printf '  PASS marker in an ordinary file does not exempt it\n'
    pass=$((pass + 1))
else
    printf '  FAIL a file is exempted by its own content — forgeable bypass\n' >&2
    fail=$((fail + 1))
fi
rm -rf "$decoy"

echo
echo "== must NOT block: the scanner's own pattern definition =="
# The pattern list contains every string it searches for, so the scanner
# would otherwise refuse to let its own source be committed.
selfrepo=$(mktemp -d)
git -C "$selfrepo" init --quiet
git -C "$selfrepo" config user.email t@example.com
git -C "$selfrepo" config user.name Test
mkdir -p "$selfrepo/hooks"
cp "$HOOK" "$selfrepo/hooks/pre-commit"
git -C "$selfrepo" add hooks/pre-commit
selfout=$( (cd "$selfrepo" && bash "$HOOK") 2>&1 )
if printf '%s' "$selfout" | grep -q 'BLOCKING'; then
    printf '  FAIL scanner blocks its own source\n' >&2
    fail=$((fail + 1))
else
    printf '  PASS scanner does not block its own source\n'
    pass=$((pass + 1))
fi
rm -rf "$selfrepo"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
