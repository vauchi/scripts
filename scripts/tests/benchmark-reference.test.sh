#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# GitLab rejects the whole consuming pipeline even when benchmarks do not run.
awk '
    /^[.a-zA-Z][^ ]*:/ { name=$0; sub(/:.*/, "", name) }
    index($0, "!reference [" name ", script]") {
        print "FAIL: circular script reference in " name > "/dev/stderr"
        exit 1
    }
' "$SCRIPT_DIR/../../ci-templates/benchmark.yml"
printf 'ok — benchmark scripts do not reference themselves\n'
