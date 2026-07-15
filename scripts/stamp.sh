#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Shared TDD stamp management for pre-push hooks.
# After `just check` passes, a stamp file is written with the HEAD commit hash.
# Pre-push hooks skip checks when the stamp matches HEAD (checks already ran).
#
# Usage:
#   source scripts/scripts/stamp.sh
#   stamp_file "core"       # → core/target/.checks-passed
#   stamp_write "core"      # writes HEAD hash to stamp file
#   stamp_valid "core"      # returns 0 if stamp matches HEAD

# Workspace root (parent of scripts/)
set -euo pipefail

_STAMP_WS_ROOT="${_STAMP_WS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Returns the stamp file path for a repo name.
stamp_file() {
    local repo="${1:?stamp_file requires a repo name}"
    case "$repo" in
        core|cli|tui|relay|e2e)
            echo "$_STAMP_WS_ROOT/$repo/target/.checks-passed" ;;
        android)
            echo "$_STAMP_WS_ROOT/android/.gradle/.checks-passed" ;;
        ios)
            echo "$_STAMP_WS_ROOT/ios/.build/.checks-passed" ;;
        linux-gtk|linux-qt|macos|windows)
            echo "$_STAMP_WS_ROOT/$repo/target/.checks-passed" ;;
        *)
            # Non-checkable repos (docs, locales, etc.) — no stamp
            echo ""
            return 1 ;;
    esac
}

# Writes the current HEAD hash to the stamp file for a repo.
stamp_write() {
    local repo="${1:?stamp_write requires a repo name}"
    local dir
    dir="$_STAMP_WS_ROOT/$repo"

    local sf
    sf=$(stamp_file "$repo") || return 0
    [[ -z "$sf" ]] && return 0

    local head
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1

    mkdir -p "$(dirname "$sf")"
    echo "$head" > "$sf"
}

# Returns 0 if the stamp matches the current HEAD (checks already passed).
stamp_valid() {
    local repo="${1:?stamp_valid requires a repo name}"
    local dir
    dir="$_STAMP_WS_ROOT/$repo"

    local sf
    sf=$(stamp_file "$repo") || return 1
    [[ -z "$sf" ]] && return 1
    [[ -f "$sf" ]] || return 1

    local stamped head
    stamped=$(<"$sf")
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1

    [[ "$stamped" == "$head" ]]
}

# Maps a directory basename (from git hooks) to a stamp repo name.
stamp_repo_from_dir() {
    local dir_name="${1:?stamp_repo_from_dir requires a directory name}"
    case "$dir_name" in
        core|cli|tui|relay|e2e|android|ios|linux-gtk|linux-qt|macos|windows)
            echo "$dir_name" ;;
        *)
            echo ""
            return 1 ;;
    esac
}
