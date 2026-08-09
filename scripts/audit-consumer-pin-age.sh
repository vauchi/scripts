#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# How far behind core main is each consumer's EFFECTIVE core revision?
#
# The manifest is not the answer. A consumer declaring `branch = "main"`
# reads as always-current, but Cargo.lock pins one revision and cargo
# will not move it without an explicit `cargo update`. web-demo looked
# like a branch-tracking consumer for five and a half weeks while sitting
# 773 commits behind core (2026-06-12-web-demo-core-lock-freeze). A tag
# pin has the same effect, just visibly.
#
# So this resolves the revision cargo would actually build, from the
# lockfile, and measures it against core main.
#
# Reports only. Whether staleness should warn or gate, and at what
# threshold, is open — see
# `problems/2026-08-09-consumer-pin-staleness-unguarded/`. Setting a
# threshold before seeing the distribution is how 773 went unnoticed and
# 107 went unremarked.
#
# Usage:
#   audit-consumer-pin-age.sh [workspace_root]        table on stdout
#   audit-consumer-pin-age.sh --json [workspace_root] JSON snapshot
#
# Exit: 0 always (a report, not a gate); 2 on internal error.
#
# Portability: POSIX shell + git. No bash arrays, no GNU-only flags.
set -eu

JSON=0
if [ "${1:-}" = "--json" ]; then
    JSON=1
    shift
fi

WORKSPACE_ROOT="${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}"
# Absolute, so paths from `find` compare against git's absolute
# --show-toplevel. Passing a relative root otherwise made every prefix
# strip fail and every lock look untracked.
WORKSPACE_ROOT=$(CDPATH='' cd -- "$WORKSPACE_ROOT" && pwd)
CORE="$WORKSPACE_ROOT/core"

if [ ! -d "$CORE/.git" ]; then
    printf 'audit-consumer-pin-age: no core checkout at %s\n' "$CORE" >&2
    exit 2
fi

# Measure against origin/main, not the local branch: a session sitting on
# a feature branch would otherwise report everything as ahead.
BASE=$(git -C "$CORE" rev-parse origin/main 2>/dev/null) || {
    printf 'audit-consumer-pin-age: cannot resolve core origin/main\n' >&2
    exit 2
}

# Consumers are discovered, not listed, so a new repo is measured the day
# it appears rather than the day someone remembers to add it here.
# Depth 4 because not every consumer keeps its lock at the repo root —
# web-demo's lives in `wasm/`, and that is the repo with the 773-commit
# history, so a shallower search would miss precisely the worst case.
# Worktrees are checkouts of repos already counted, and vendored/target
# trees are build output.
consumers=$(find "$WORKSPACE_ROOT" -maxdepth 4 -name Cargo.lock \
    -not -path '*/target/*' -not -path '*/.worktrees/*' \
    -not -path '*/node_modules/*' -not -path '*/vendor/*' 2>/dev/null |
    while IFS= read -r lock; do
        grep -q 'git+https://gitlab.com/vauchi/core\.git' "$lock" 2>/dev/null && printf '%s\n' "$lock"
    done | sort)

emit_row() {  # repo pin_kind pin_value rev behind days
    if [ "$JSON" -eq 1 ]; then
        printf '    { "repo": "%s", "pin_kind": "%s", "pin": "%s", "rev": "%s", "commits_behind": %s, "days_old": %s }' \
            "$1" "$2" "$3" "$4" "$5" "$6"
    else
        printf '  %-12s %-8s %-22s %-10s %8s %8s\n' "$1" "$2" "$3" "$4" "$5" "$6"
    fi
}

[ "$JSON" -eq 1 ] && printf '{\n  "base": "%s",\n  "consumers": [\n' "$(echo "$BASE" | cut -c1-8)"
[ "$JSON" -eq 0 ] && {
    printf '\n=== Consumer pin age vs core origin/main (%s) ===\n\n' "$(echo "$BASE" | cut -c1-8)"
    printf '  %-12s %-8s %-22s %-10s %8s %8s\n' repo pin declared rev behind days
    printf '  %-12s %-8s %-22s %-10s %8s %8s\n' ------------ -------- ---------------------- ---------- -------- --------
}

first=1
for lock in $consumers; do
    dir=$(dirname "$lock")
    # Name by the repo, not the crate directory: web-demo's lock lives in
    # `wasm/`, and reporting that as "wasm" hides which repo is stale.
    rel=${dir#"$WORKSPACE_ROOT"/}
    repo=$(printf '%s' "$rel" | cut -d/ -f1)
    sub=$(printf '%s' "$rel" | cut -s -d/ -f2-)
    [ -n "$sub" ] && repo="$repo/$sub"
    case "$repo" in core|core/*) continue ;; esac

    # The revision cargo resolved — the fragment after '#' in the source URL.
    rev=$(grep -m1 -oE 'git\+https://gitlab\.com/vauchi/core\.git[^"]*#[0-9a-f]+' "$lock" 2>/dev/null |
        sed 's/.*#//' | cut -c1-40)
    [ -z "$rev" ] && continue

    # What the manifest claims, so both staleness shapes are visible side
    # by side: an old tag looks old, an old lock behind `branch = "main"`
    # does not.
    manifest="$dir/Cargo.toml"
    pin_kind="?"; pin_value="?"
    if [ -f "$manifest" ]; then
        decl=$(grep -m1 -oE 'vauchi-(core|app|platform|protocol) = \{ git[^}]*\}' "$manifest" 2>/dev/null || true)
        case "$decl" in
            *tag\ =\ *)    pin_kind="tag";    pin_value=$(printf '%s' "$decl" | sed -E 's/.*tag = "([^"]*)".*/\1/') ;;
            *branch\ =\ *) pin_kind="branch"; pin_value=$(printf '%s' "$decl" | sed -E 's/.*branch = "([^"]*)".*/\1/') ;;
            *rev\ =\ *)    pin_kind="rev";    pin_value=$(printf '%s' "$decl" | sed -E 's/.*rev = "([^"]*)".*/\1/') ;;
        esac
    fi

    # An untracked lock is local state, not shared: CI resolves it from
    # scratch on a fresh runner, so its age says nothing about what the
    # project builds. relay/fuzz's lock is gitignored and read as 568
    # commits stale here while CI was resolving current main — reporting
    # that as a project-wide finding would have been wrong.
    tracked="yes"
    repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$repo_root" ]; then
        rel_lock=${lock#"$repo_root"/}
        git -C "$repo_root" ls-files --error-unmatch "$rel_lock" >/dev/null 2>&1 || tracked="no"
    fi

    if [ "$tracked" = "no" ]; then
        pin_kind="untracked"
        pin_value="local lock only"
    fi

    if git -C "$CORE" cat-file -e "$rev^{commit}" 2>/dev/null; then
        behind=$(git -C "$CORE" rev-list --count "$rev".."$BASE" 2>/dev/null || echo -1)
        ts=$(git -C "$CORE" log -1 --format=%ct "$rev" 2>/dev/null || echo 0)
        now=$(git -C "$CORE" log -1 --format=%ct "$BASE" 2>/dev/null || echo 0)
        if [ "$ts" -gt 0 ] && [ "$now" -ge "$ts" ]; then
            days=$(( (now - ts) / 86400 ))
        else
            days=-1
        fi
    else
        # Not fetched locally. Reported rather than skipped: an unknown
        # revision is itself a finding — nobody can say how old it is.
        behind=-1
        days=-1
    fi

    [ "$JSON" -eq 1 ] && [ "$first" -eq 0 ] && printf ',\n'
    emit_row "$repo" "$pin_kind" "$pin_value" "$(echo "$rev" | cut -c1-8)" "$behind" "$days"
    first=0
done

if [ "$JSON" -eq 1 ]; then
    printf '\n  ]\n}\n'
else
    printf '\n  behind/days of -1 means the revision is not in the local core\n'
    printf '  checkout — run: git -C core fetch --tags origin\n\n'
fi
