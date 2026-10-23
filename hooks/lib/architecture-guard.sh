#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=${1:?repository root required}
[[ -f "$root/vauchi-core/Cargo.toml" ]] || exit 0
gate="$root/../scripts/scripts/architecture-check.sh"
if [[ ! -f "$gate" ]]; then
    echo 'VRS06: architecture gate is missing; update the scripts checkout before pushing Core.' >&2
    exit 1
fi
bash "$gate" "$root" check origin/main
