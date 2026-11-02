#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Sets core.hooksPath in all repos to use shared hooks from scripts/hooks/.
# No symlinks or copies — git reads hooks directly from the shared directory.
# Usage: ./scripts/install-hooks.sh
# Idempotent — safe to re-run on pull or setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_GIT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir)"
case "$COMMON_GIT_DIR" in
    /*) ;;
    *) COMMON_GIT_DIR="$SCRIPT_DIR/$COMMON_GIT_DIR" ;;
esac
CANONICAL_SCRIPTS_DIR="$(cd "$(dirname "$COMMON_GIT_DIR")" && pwd)"
REPO_ROOT="$(dirname "$CANONICAL_SCRIPTS_DIR")"
HOOKS_DIR="$CANONICAL_SCRIPTS_DIR/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "No hooks directory found at $HOOKS_DIR"
    exit 1
fi

chmod +x "$HOOKS_DIR"/*

# All repos that get hooks (auto-discover all .git dirs, skip archived)
REPOS=()
# Tools and forks are cloned one level down, under utils/ (private#1034).
for dir in "$REPO_ROOT" "$REPO_ROOT"/*/ "$REPO_ROOT"/utils/*/; do
    dir="${dir%/}"
    [[ -d "$dir/.git" ]] || continue
    name="$(basename "$dir")"
    # Skip archived repos
    case "$name" in
        vauchi-platform-kotlin|desktop) continue ;;
    esac
    REPOS+=("$dir")
done

echo "Setting core.hooksPath → $HOOKS_DIR"

for repo in "${REPOS[@]}"; do
    name="$(basename "$repo")"
    if [[ -d "$repo/.git" ]]; then
        git -C "$repo" config core.hooksPath "$HOOKS_DIR"
        echo "  OK: $name"
    else
        echo "  SKIP: $name (not cloned)"
    fi
done

echo "Done!"
