#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT

workspace="$test_root/workspace"
target="$test_root/target"
mkdir -p "$workspace" "$target/scripts"
touch "$workspace/CLAUDE.md"
cp scripts/resolve-repo.sh "$target/scripts/resolve-repo.sh"
ln -s "$target" "$workspace/scripts"

for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        echo "SKIP ($shell): not installed"
        continue
    fi

    resolved="$(
        "$shell" -c '
            cd "$1"
            source "$1/scripts/scripts/resolve-repo.sh"
            gitlab_repo_dir scripts
        ' _ "$workspace"
    )"

    if [[ "$resolved" != "$target" ]]; then
        echo "FAIL ($shell): expected canonical repo path '$target', got '$resolved'"
        exit 1
    fi

    echo "PASS ($shell): gitlab_repo_dir canonicalizes symlinked worktree paths"
done
