#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# lib/resolve-tool.sh finds a tool the hooks run: the copy the workspace
# root pins in node_modules/.bin first, then one on PATH, and either only
# when it runs. On WSL the PATH holds the Windows npm shim of markdownlint,
# which exits 127 there; a bare `command -v` took it for an installed tool
# (vauchi/private#1385).

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/lib/resolve-tool.sh"
pass=0
fail=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        printf '  PASS %s\n' "$1"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2
        fail=$((fail + 1))
    fi
}

# tool <path> <exit status>: a stand-in that answers --version with that status.
tool() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$1" "$2" >"$1"
    chmod +x "$1"
}

resolve() {  # resolve <workspace root> <PATH dir>
    PATH="$2:/usr/bin:/bin" sh -c '. "$1"; resolve_tool mdtool "$2"' _ "$LIB" "$1"
}

root=$(mktemp -d)
ws="$root/ws"
onpath="$root/path"
mkdir -p "$ws" "$onpath"

tool "$ws/node_modules/.bin/mdtool" 0
tool "$onpath/mdtool" 0
assert_eq "the workspace's pinned copy comes before PATH" \
    "$ws/node_modules/.bin/mdtool" "$(resolve "$ws" "$onpath")"

rm "$ws/node_modules/.bin/mdtool"
assert_eq "without a pinned copy, the one on PATH" \
    "$onpath/mdtool" "$(resolve "$ws" "$onpath")"

tool "$onpath/mdtool" 127
out=$(resolve "$ws" "$onpath"); rc=$?
assert_eq "a PATH copy that cannot run is no tool: nothing printed" "" "$out"
assert_eq "a PATH copy that cannot run is no tool: status 1" "1" "$rc"

tool "$ws/node_modules/.bin/mdtool" 1
tool "$onpath/mdtool" 0
assert_eq "a pinned copy that fails gives way to a PATH copy that runs" \
    "$onpath/mdtool" "$(resolve "$ws" "$onpath")"

rm "$ws/node_modules/.bin/mdtool" "$onpath/mdtool"
out=$(resolve "$ws" "$onpath"); rc=$?
assert_eq "no copy at all: status 1" "1" "$rc"
assert_eq "no copy at all: nothing printed" "" "$out"

rm -rf "$root"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
