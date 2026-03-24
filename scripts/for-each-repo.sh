#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# for-each-repo.sh — Shared multi-repo iteration helper
#
# Source this file, then call for_each_repo with a callback function.
# The callback receives two arguments: label dir
#
# Usage:
#   source scripts/scripts/for-each-repo.sh
#
#   my_callback() { local label="$1" dir="$2"; echo "$label: $dir"; }
#   for_each_repo my_callback             # includes root, sequential
#   for_each_repo --no-root my_callback   # excludes root
#   for_each_repo_parallel my_callback    # includes root, parallel (& + wait)

for_each_repo() {
    local include_root=true
    if [[ "${1:-}" == "--no-root" ]]; then
        include_root=false
        shift
    fi
    local callback="$1"

    if $include_root && [[ -d ".git" ]]; then
        "$callback" "vauchi (root)" "."
    fi

    local dir
    for dir in */; do
        [[ -d "${dir}.git" ]] || continue
        "$callback" "${dir%/}" "${dir%/}"
    done
}

# Parallel variant — backgrounds each callback invocation, waits for all.
# Caller must handle inter-process communication via temp files, not arrays
# (backgrounded subshells cannot modify parent shell variables).
for_each_repo_parallel() {
    local include_root=true
    if [[ "${1:-}" == "--no-root" ]]; then
        include_root=false
        shift
    fi
    local callback="$1"

    if $include_root && [[ -d ".git" ]]; then
        "$callback" "vauchi (root)" "." &
    fi

    local dir
    for dir in */; do
        [[ -d "${dir}.git" ]] || continue
        "$callback" "${dir%/}" "${dir%/}" &
    done
    wait
}
