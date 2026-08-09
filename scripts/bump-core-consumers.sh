#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Move every consumer's effective core revision forward.
#
# Measured 2026-08-09, every consumer was behind core main — median ~104
# commits, worst 568. Two shapes, one cause:
#
#   branch = "main"   the manifest reads as always-current, but
#                     Cargo.lock pins a revision and cargo will not move
#                     it without an explicit update. tui/linux-gtk/relay
#                     were 73/104/139 behind while declaring `main`.
#                     Here the lock alone is refreshed — the declared
#                     intent is already "track main", so honouring it
#                     needs no manifest edit.
#
#   tag = "vX"        the pin is explicit and only moves when edited.
#                     Here both the manifest tag and the lock advance to
#                     the newest core tag.
#
# The point is increment size. web-demo once absorbed 773 commits in one
# bump and the breakage arrived all at once
# (2026-06-12-web-demo-core-lock-freeze). Bumping often makes each
# migration small and each failure attributable.
#
# This does NOT commit or push. It edits the working tree and reports
# what moved, so a caller — a scheduled job, or a person — decides what
# to do with a bump that fails to build. A red bump is a finding, not a
# thing to hide.
#
# Usage:
#   bump-core-consumers.sh [--dry-run] [--repo NAME] [--build] [workspace]
#
#     --dry-run   report what would change, touch nothing
#     --repo      limit to one consumer (default: all)
#     --build     `cargo check` each bumped consumer and report the result
#
# Exit: 0 if every attempted bump resolved (build failures are reported,
#       not fatal — see above); 1 on a resolve failure; 2 on usage error.
#
# Portability: POSIX shell. Requires git and cargo.
set -eu

DRY=0
ONLY=""
BUILD=0
WORKSPACE_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --build)   BUILD=1; shift ;;
        --repo)    ONLY="${2:-}"; shift 2 ;;
        --help|-h) sed -n '5,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)       printf 'bump-core-consumers: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)         WORKSPACE_ROOT="$1"; shift ;;
    esac
done

if [ -z "$WORKSPACE_ROOT" ]; then
    WORKSPACE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fi
CORE="$WORKSPACE_ROOT/core"

[ -d "$CORE/.git" ] || {
    printf 'bump-core-consumers: no core checkout at %s\n' "$CORE" >&2
    exit 2
}

git -C "$CORE" fetch --tags --quiet origin 2>/dev/null || true
BASE=$(git -C "$CORE" rev-parse --short origin/main)

# Newest core tag by creation date. Dev tags are the cadence here; a
# consumer pinned to a tag can only move to a tag that exists, which is
# why cli!498 sat blocked until one was cut.
LATEST_TAG=$(git -C "$CORE" tag --sort=-creatordate | head -1)

printf '=== core: main %s, newest tag %s ===\n\n' "$BASE" "${LATEST_TAG:-<none>}"

changed=0
failed=0

# Same discovery as audit-consumer-pin-age.sh: found, not listed, so a
# new consumer is bumped the day it appears rather than the day someone
# remembers to add it.
locks=$(find "$WORKSPACE_ROOT" -maxdepth 4 -name Cargo.lock \
    -not -path '*/target/*' -not -path '*/.worktrees/*' \
    -not -path '*/node_modules/*' -not -path '*/vendor/*' 2>/dev/null |
    while IFS= read -r l; do
        grep -q 'git+https://gitlab.com/vauchi/core\.git' "$l" 2>/dev/null && printf '%s\n' "$l"
    done | sort)

for lock in $locks; do
    dir=$(dirname "$lock")
    rel=${dir#"$WORKSPACE_ROOT"/}
    repo=$(printf '%s' "$rel" | cut -d/ -f1)
    case "$repo" in core) continue ;; esac
    [ -n "$ONLY" ] && [ "$ONLY" != "$repo" ] && continue

    manifest="$dir/Cargo.toml"
    [ -f "$manifest" ] || continue

    before=$(grep -m1 -oE 'git\+https://gitlab\.com/vauchi/core\.git[^"]*#[0-9a-f]+' "$lock" |
        sed 's/.*#//' | cut -c1-8)

    decl=$(grep -m1 -oE 'vauchi-(core|app|platform|protocol) = \{ git[^}]*\}' "$manifest" 2>/dev/null || true)
    case "$decl" in
        *branch\ =\ *) mode="lock" ;;
        *tag\ =\ *)    mode="tag" ;;
        *)
            # No direct declaration, but the lock resolves core — a
            # transitive consumer such as relay/fuzz, which reaches core
            # through vauchi-relay by path yet carries its own lock. It
            # was the stalest thing measured (568 commits, 34 days) while
            # its nightly libfuzzer ran against that revision, so
            # skipping it would miss the worst case.
            mode="lock"
            ;;
    esac

    if [ "$mode" = "tag" ]; then
        current_tag=$(printf '%s' "$decl" | sed -E 's/.*tag = "([^"]*)".*/\1/')
        if [ -z "$LATEST_TAG" ] || [ "$current_tag" = "$LATEST_TAG" ]; then
            printf '  %-16s ok    tag %s is newest\n' "$rel" "$current_tag"
            continue
        fi
    fi

    if [ "$DRY" -eq 1 ]; then
        if [ "$mode" = "tag" ]; then
            printf '  %-16s would  %s -> %s (and refresh lock)\n' "$rel" "$current_tag" "$LATEST_TAG"
        else
            printf '  %-16s would  refresh lock from %s toward main\n' "$rel" "$before"
        fi
        continue
    fi

    if [ "$mode" = "tag" ]; then
        # Rewrite only the core git deps, never an unrelated `tag =`.
        #
        # `#` delimits, not `|`: the pattern needs `|` for the crate-name
        # alternation, and using it as the delimiter too ends the s///
        # early — BSD sed reports "parentheses not balanced", GNU sed
        # fails differently. The first version of this did exactly that
        # and then reported the repo as already current, because the
        # failure was swallowed by `&&`.
        tmp="$manifest.bump.$$"
        if ! sed -E "s#(vauchi-(core|app|platform|protocol) = \{ git = \"https://gitlab\.com/vauchi/core\.git\"[^}]*tag = \")[^\"]*(\")#\1$LATEST_TAG\3#g" \
            "$manifest" > "$tmp"; then
            rm -f "$tmp"
            printf '  %-16s FAIL  could not rewrite the tag in Cargo.toml\n' "$rel"
            failed=$((failed + 1))
            continue
        fi
        mv "$tmp" "$manifest"

        # Prove the edit landed. A silent no-op here would leave the lock
        # refresh resolving the OLD tag and the repo reported as current.
        if ! grep -q "tag = \"$LATEST_TAG\"" "$manifest"; then
            printf '  %-16s FAIL  tag rewrite produced no change\n' "$rel"
            failed=$((failed + 1))
            continue
        fi
    fi

    # Re-resolve. For a branch dep this walks the lock to the branch tip;
    # for a tag dep it follows the tag just written.
    if ! (cd "$dir" && cargo update -p vauchi-core -p vauchi-app >/dev/null 2>&1) &&
       ! (cd "$dir" && cargo update >/dev/null 2>&1); then
        printf '  %-16s FAIL  could not resolve\n' "$rel"
        failed=$((failed + 1))
        continue
    fi

    after=$(grep -m1 -oE 'git\+https://gitlab\.com/vauchi/core\.git[^"]*#[0-9a-f]+' "$lock" |
        sed 's/.*#//' | cut -c1-8)

    if [ "$before" = "$after" ]; then
        printf '  %-16s ok    already at %s\n' "$rel" "$after"
        continue
    fi

    behind=$(git -C "$CORE" rev-list --count "$after"..origin/main 2>/dev/null || echo '?')
    printf '  %-16s BUMP  %s -> %s (%s behind main)\n' "$rel" "$before" "$after" "$behind"
    changed=$((changed + 1))

    if [ "$BUILD" -eq 1 ]; then
        if (cd "$dir" && cargo check --quiet >/dev/null 2>&1); then
            printf '  %-16s       build OK\n' ''
        else
            # Reported, never reverted: a bump that breaks the build is
            # the accumulated drift becoming visible, which is the whole
            # purpose. Hiding it recreates the 773-commit surprise.
            printf '  %-16s       BUILD FAILS — real breakage, needs a fix\n' ''
        fi
    fi
done

printf '\n%d consumer(s) bumped, %d failed to resolve\n' "$changed" "$failed"
[ "$failed" -eq 0 ]
