#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
repo=${1:?usage: core-release-pin-warning.sh repo}
[ -f "$repo/Cargo.toml" ] || exit 0
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if message=$(python3 "$script_dir/../../scripts/core-pins.py" require-release \
    --kind cargo --if-present "$repo/Cargo.toml" --lockfile "$repo/Cargo.lock" 2>&1); then
    exit 0
fi
printf '  WARNING: Core pin blocks merge; candidate pushes remain allowed.\n  %s\n' "$message"
