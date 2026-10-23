#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
gate=${1:-$script_dir/../architecture-check.sh}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/core" "$fixture/bin"
ln -s "$(command -v dirname)" "$fixture/bin/dirname"
for missing in cargo rustc git; do
    for tool in cargo rustc git; do
        rm -f "$fixture/bin/$tool"
        if [[ "$tool" != "$missing" ]]; then
            ln -s /bin/true "$fixture/bin/$tool"
        fi
    done
    actual=0
    PATH="$fixture/bin" /bin/bash "$gate" "$fixture/core" check HEAD > "$fixture/log" 2>&1 || actual=$?
    if [[ "$actual" != 2 ]] || ! grep -Fxq "VRS06: missing required tool: $missing" "$fixture/log"; then
        cat "$fixture/log" >&2
        echo "FAIL: missing $missing must fail with its named diagnostic (got $actual)" >&2
        exit 1
    fi
    echo "PASS: missing $missing fails closed"
done
