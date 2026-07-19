#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# git-helpers.sh — Shared git utilities for justfile recipes.
#
# Usage: source scripts/scripts/git-helpers.sh
#
#   is_branch_in_main <dir> <branch>
#     Returns 0 if <branch> is merged into origin/main (by ancestry or content).
#
#   list_merged_branches <dir>
#     Outputs one branch name per line — local branches whose content is in origin/main.

# Check if a single branch is merged into origin/main.
# Uses git ancestry first, falls back to diff-based content check
# (catches rebased/squashed branches that are content-equivalent).
set -euo pipefail

is_branch_in_main() {
    local dir="$1" branch="$2"
    # Fast path: git ancestry check
    if git -C "$dir" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
        return 0
    fi
    # Slow path: content-equivalent (diff is empty)
    if git -C "$dir" diff --quiet origin/main..."$branch" -- 2>/dev/null; then
        return 0
    fi
    return 1
}

# List all local branches whose content is in origin/main.
# Outputs one branch name per line (excludes current branch and main).
list_merged_branches() {
    local dir="$1"

    # Phase 1: branches git knows are ancestors of origin/main
    local merged
    merged=$(git -C "$dir" branch --merged origin/main 2>/dev/null \
        | grep -vE '^\*|^[[:space:]]+main$' \
        | sed 's/^[[:space:]+]*//' || true)

    # Phase 2: branches whose content equals main (rebased/squashed)
    local all_local candidate
    all_local=$(git -C "$dir" branch --no-color 2>/dev/null \
        | grep -vE '^\*|^[[:space:]]+main$' \
        | sed 's/^[[:space:]+]*//' || true)
    for candidate in $all_local; do
        echo "$merged" | grep -qxF "$candidate" && continue
        if git -C "$dir" diff --quiet origin/main..."$candidate" -- 2>/dev/null; then
            merged=$(printf '%s\n%s' "$merged" "$candidate")
        fi
    done

    # Output clean list (no empty lines)
    echo "$merged" | sed '/^$/d'
}
