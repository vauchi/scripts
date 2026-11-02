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

# Repos under utils/ (vauchi/utils, private#1034) resolve through the
# registry's directory column: the GitLab project is vauchi/utils/<name>
# and the working directory is utils/<name>, for every registered fork,
# not only the names a case statement once listed.
mkdir -p "$workspace/utils/somefork/.git" "$workspace/core/.git"
for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out="$(
        "$shell" -c '
            cd "$1"
            source "$1/scripts/scripts/resolve-repo.sh"
            REPO_REGISTRY=("somefork:utils/somefork:none" "core:core:rust")
            resolve_gitlab_project somefork
            resolve_gitlab_project core
            gitlab_repo_dir somefork
        ' _ "$workspace"
    )"
    expected="vauchi/utils/somefork
vauchi/core
$workspace/utils/somefork"
    if [[ "$out" != "$expected" ]]; then
        echo "FAIL ($shell): utils/ repos resolve through the registry; got:"
        printf '%s\n' "$out"
        exit 1
    fi
    echo "PASS ($shell): utils/ repos resolve to vauchi/utils/<name> and utils/<name>"
done
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later


# At the workspace root with no repo argument, the GitLab directory is the
# root checkout itself. Detection names it "root", which the registry does
# not list, so `just gitlab mr-create` failed with "cd: null directory".
mkdir -p "$workspace/.git"
for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    out="$(
        "$shell" -c '
            cd "$1"
            source "$1/scripts/scripts/resolve-repo.sh"
            REPO_REGISTRY=("core:core:rust")
            gitlab_repo_dir
        ' _ "$workspace" 2>&1
    )" || true
    if [[ "$out" != "$workspace" ]]; then
        echo "FAIL ($shell): gitlab_repo_dir at the root must name the root; got: $out"
        exit 1
    fi
    echo "PASS ($shell): gitlab_repo_dir with no argument at the root names the root checkout"
done