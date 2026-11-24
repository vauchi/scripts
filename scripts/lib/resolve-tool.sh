# shellcheck shell=sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced, POSIX sh. resolve_tool <name> <workspace root> prints a copy of
# <name> that runs: the one the workspace root pins in node_modules/.bin
# first, so every host and CI run the same version, then one on PATH. A
# copy counts only when `<copy> --version` exits 0: on WSL the PATH can
# hold a Windows npm shim that exits 127 (vauchi/private#1385). Returns 1
# when there is none, so the caller can say it skipped.

resolve_tool() {
    _resolve_tool_pinned="$2/node_modules/.bin/$1"
    _resolve_tool_found=$(command -v "$1" 2>/dev/null) || _resolve_tool_found=""
    for _resolve_tool_copy in "$_resolve_tool_pinned" "$_resolve_tool_found"; do
        [ -n "$_resolve_tool_copy" ] && [ -x "$_resolve_tool_copy" ] || continue
        if "$_resolve_tool_copy" --version >/dev/null 2>&1; then
            printf '%s\n' "$_resolve_tool_copy"
            return 0
        fi
    done
    return 1
}
