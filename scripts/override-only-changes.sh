#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# override-only-changes.sh <repo-dir>
#
# Exit 0 iff EVERY working-tree change (staged + unstaged) in the repo
# is `just setup-path-overrides` churn — the documented persistent
# local-dev state that the pre-commit hook refuses to let anyone
# commit. Exit 1 for anything else, including a clean tree.
#
# Tolerated, content-verified:
#   - Cargo.toml whose diff vs HEAD is additions-only and entirely
#     inside the fence markers (blank separator lines allowed)
#   - Cargo.lock changes, only while the sibling Cargo.toml carries
#     the fence (override active); lock diffs are not content-checked
#     because real lock-only work without any other change is not a
#     state this filter is allowed to bless — see test #8
# Everything else fails: untracked files, deletions, renames,
# Cargo.toml edits outside the fence, lock churn without a fence.
#
# Consumers: `just session-end` (downgrade ERROR to info) and
# `just git wip` auto-collect (skip, so the fence is never
# WIP-committed again). Both fall back to strict behavior when this
# script is missing.
# Problem record: 2026-06-11-session-end-override-false-positives.

set -euo pipefail

BEGIN_MARKER='# >>> setup-path-overrides BEGIN'

dir="${1:-.}"

status=$(git -C "$dir" status --porcelain 2>/dev/null) || exit 1
[ -n "$status" ] || exit 1

# Diff vs HEAD must be additions-only and confined to the fence.
toml_is_fence_only() {
    git -C "$dir" diff HEAD -- "$1" | awk '
        /^--- / || /^\+\+\+ / { next }
        /^-/ { bad = 1 }
        /^\+/ {
            line = substr($0, 2)
            if (line ~ /setup-path-overrides BEGIN/) { fence = 1; seen = 1; next }
            if (line ~ /setup-path-overrides END/)   { fence = 0; next }
            if (fence) next
            if (line ~ /^[[:space:]]*$/) next
            bad = 1
        }
        END { exit (bad || !seen) ? 1 : 0 }
    '
}

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    xy="${entry%"${entry#??}"}"
    path="${entry#???}"

    case "$xy" in
        '??') exit 1 ;;            # untracked is never override churn
    esac
    case "$path" in
        *' -> '*) exit 1 ;;        # renames are never override churn
    esac

    [ -f "$dir/$path" ] || exit 1  # deletions are never override churn

    case "${path##*/}" in
        Cargo.toml)
            toml_is_fence_only "$path" || exit 1
            ;;
        Cargo.lock)
            sibling="${path%Cargo.lock}Cargo.toml"
            grep -qF "$BEGIN_MARKER" "$dir/$sibling" 2>/dev/null || exit 1
            ;;
        *)
            exit 1
            ;;
    esac
done <<EOF_STATUS
$status
EOF_STATUS

exit 0
