#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# stamp.sh names a stamp file for each checkable repository. windows was
# renamed to windows-app (private#1234); a checkout under either name keeps
# its stamp, and a repository with no checks has none.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$SCRIPT_DIR/../stamp.sh"
pass=0
fail=0

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got"
    fi
}

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT

stamp_of() {
    _STAMP_WS_ROOT="$workspace" bash -c 'source "$1" && stamp_file "$2"' _ "$STAMP" "$1"
}

repo_of() {
    _STAMP_WS_ROOT="$workspace" bash -c 'source "$1" && stamp_repo_from_dir "$2"' _ "$STAMP" "$1"
}

check "windows-app has a stamp" "$workspace/windows-app/target/.checks-passed" "$(stamp_of windows-app)"
check "windows keeps its stamp" "$workspace/windows/target/.checks-passed" "$(stamp_of windows)"
check "the windows-app directory is a checkable repository" "windows-app" "$(repo_of windows-app)"
check "the windows directory is a checkable repository" "windows" "$(repo_of windows)"
check "gtk-display has a stamp" "$workspace/gtk-display/target/.checks-passed" "$(stamp_of gtk-display)"
check "docs has no stamp" "" "$(stamp_of docs)"
# cli and tui become cli-display and tui-display (private#1233).
for repo in cli-display tui-display cli tui; do
    check "$repo has a stamp" "$workspace/$repo/target/.checks-passed" "$(stamp_of "$repo")"
    check "the $repo directory is a checkable repository" "$repo" "$(repo_of "$repo")"
done

echo "stamp.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
