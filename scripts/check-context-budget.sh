#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT=${1:-.}
BASELINE=${2:-"$ROOT/scripts/context-budget-baseline.tsv"}
failures=0
[[ -f "$BASELINE" ]] || { echo "context-budget: baseline missing: $BASELINE" >&2; exit 1; }
while IFS=$'\t' read -r path baseline ceiling; do
    [[ -z "${path:-}" || "$path" == \#* ]] && continue
    file="$ROOT/$path"
    if [[ ! -f "$file" ]]; then
        echo "context-budget: missing tracked input: $path" >&2
        failures=$((failures + 1))
        continue
    fi
    actual=$(wc -c < "$file" | tr -d ' ')
    if (( actual > ceiling )); then
        echo "context-budget: $path grew to $actual bytes (ceiling $ceiling; baseline $baseline)" >&2
        failures=$((failures + 1))
    else
        echo "context-budget: $path $actual/$ceiling bytes"
    fi
done < "$BASELINE"
(( failures == 0 ))
