#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

workspace="$test_root/workspace"
target="$test_root/target"
mkdir -p "$workspace" "$target/scripts"
touch "$workspace/CLAUDE.md"
cp scripts/resolve-repo.sh "$target/scripts/resolve-repo.sh"
ln -s "$target" "$workspace/scripts"

resolved="$(
    cd "$workspace"
    # shellcheck disable=SC1091
    source "$workspace/scripts/scripts/resolve-repo.sh"
    gitlab_repo_dir scripts
)"

if [[ "$resolved" != "$target" ]]; then
    echo "FAIL: expected canonical repo path '$target', got '$resolved'"
    exit 1
fi

echo "PASS: gitlab_repo_dir canonicalizes symlinked worktree paths"
