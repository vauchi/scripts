#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Sets core.hooksPath in all repos to use shared hooks from scripts/hooks/.
# No symlinks or copies — git reads hooks directly from the shared directory.
# Usage: ./scripts/install-hooks.sh
# Idempotent — safe to re-run on pull or setup.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$SCRIPT_DIR/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "No hooks directory found at $HOOKS_DIR"
    exit 1
fi

chmod +x "$HOOKS_DIR"/*

# All repos that get hooks
REPOS=(
    "$REPO_ROOT"
    "$REPO_ROOT/core"
    "$REPO_ROOT/cli"
    "$REPO_ROOT/tui"
    "$REPO_ROOT/relay"
    "$REPO_ROOT/desktop"
    "$REPO_ROOT/e2e"
    "$REPO_ROOT/ios"
    "$REPO_ROOT/android"
    "$REPO_ROOT/docs"
    "$REPO_ROOT/_private"
    "$REPO_ROOT/linux-gtk"
    "$REPO_ROOT/linux-qt"
    "$REPO_ROOT/macos"
    "$REPO_ROOT/windows"
    "$REPO_ROOT/web-demo"
)

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
