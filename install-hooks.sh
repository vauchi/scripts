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
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$SCRIPT_DIR/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "No hooks directory found at $HOOKS_DIR"
    exit 1
fi

chmod +x "$HOOKS_DIR"/*

# All repos that get hooks (auto-discover all .git dirs, skip archived)
REPOS=()
for dir in "$REPO_ROOT" "$REPO_ROOT"/*/; do
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
