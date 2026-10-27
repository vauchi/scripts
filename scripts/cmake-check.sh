#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
repo=${1:?Usage: cmake-check.sh REPO [build|test]}
phase=${2:-test}
case "$phase" in build|test) ;; *) echo "Unknown CMake check phase: $phase" >&2; exit 2 ;; esac
[[ -f "$repo/CMakeLists.txt" ]] || { echo "Missing CMakeLists.txt: $repo" >&2; exit 1; }
for tool in cmake sccache; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
cmake -S "$repo" -B "$repo/build" -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
cmake --build "$repo/build" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
if [[ "$phase" == test ]]; then
    QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen} \
        ctest --test-dir "$repo/build" --output-on-failure --no-tests=error
fi
