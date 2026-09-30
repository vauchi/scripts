#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# A rebase on 2026-09-30 committed _private/docs/problems/.wip-baseline with
# both conflict sides and the markers in it; every pre-commit stage passed,
# because none looked for them and markdownlint only reads .md files
# (vauchi/private#449). The hook must block staged conflict markers in any
# file, read from the STAGED blob, and must not block a lone `=======`
# line, which is a Markdown setext heading underline.
#
# Runs the real hook against a throwaway repo, per CC-27 in both directions.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/pre-commit"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

pass=0
fail=0
# Assembled at runtime so this file does not carry the markers it tests.
OURS="<<<<<<""< HEAD"
MID="======""="
THEIRS=">>>>>>""> ae428c1f (a commit)"

# run_case <label> <path> <content> <want: block|allow> [scrub]
run_case() {
    label=$1; path=$2; content=$3; want=$4; mutation=${5:-keep}

    repo=$(mktemp -d)
    git -C "$repo" init --quiet
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name Test
    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$content" > "$repo/$path"
    git -C "$repo" add "$path"
    [ "$mutation" = scrub ] && printf 'resolved\n' > "$repo/$path"

    out=$( (cd "$repo" && bash "$HOOK") 2>&1 )
    code=$?
    blocked=no
    [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'conflict marker' && blocked=yes

    if { [ "$want" = block ] && [ "$blocked" = yes ]; } || { [ "$want" = allow ] && [ "$code" -eq 0 ]; }; then
        pass=$((pass + 1)); echo "  PASS  $label"
    else
        fail=$((fail + 1)); echo "  FAIL  $label (exit $code)"; printf '%s\n' "$out" | tail -5
    fi
    rm -rf "$repo"
}

conflict=$(printf '%s\n%s\n%s\n%s\n%s\n' "$OURS" "15" "$MID" "12" "$THEIRS")
run_case "markers in a plain file are blocked" "docs/problems/.wip-baseline" "$conflict" block
run_case "markers in a python file are blocked" "scripts/x.py" "$conflict" block
run_case "the staged blob is read, not the resolved working copy" "notes.txt" "$conflict" block scrub
run_case "a setext heading underline alone is allowed" "doc.md" "$(printf 'Title\n%s\n\nBody.\n' "$MID")" allow
run_case "a file without markers is allowed" "plain.txt" "nothing here" allow

echo "pre-commit-conflict-markers.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
