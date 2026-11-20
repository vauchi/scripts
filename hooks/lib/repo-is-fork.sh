#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: repo-is-fork.sh <repo-root>
# Exits 0 when repos.toml marks the repo at <repo-root> `fork = true`.
# A forked library keeps upstream's licensing layout (vauchi/private#1314).
# Anything uncertain (no workspace, unreadable registry, missing reader)
# exits 1, so the caller's gate stays on.
set -uo pipefail

repo_root=$(cd "${1:?usage: repo-is-fork.sh <repo-root>}" 2>/dev/null && pwd) || exit 1

workspace=""
probe="$repo_root"
while [[ "$probe" != "/" ]]; do
    probe=$(dirname "$probe")
    if [[ -f "$probe/repos.toml" ]]; then
        workspace="$probe"
        break
    fi
done
[[ -n "$workspace" ]] || exit 1

registry="$workspace/scripts/scripts/lib/repo-registry.py"
[[ -f "$registry" ]] || exit 1

relative_path="${repo_root#"$workspace"/}"
forks=$(cd "$workspace" && python3 "$registry" query fork) || exit 1
for name in $forks; do
    registered_path=$(cd "$workspace" && python3 "$registry" dir "$name") || exit 1
    [[ "$registered_path" == "$relative_path" ]] && exit 0
done
exit 1
