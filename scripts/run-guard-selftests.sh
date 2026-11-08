#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="${1:?Usage: run-guard-selftests.sh <repository>}"
if [[ ! -d "$repo_root" ]]; then
    echo "ERROR: guard selftest repository is missing: $repo_root" >&2
    exit 2
fi

completed=0
for test_script in "$repo_root"/scripts/tests/check-*.test.py \
                   "$repo_root"/ci/tests/check-*.test.py; do
    [[ -f "$test_script" ]] || continue
    echo "Guard selftest: ${test_script#"$repo_root"/}"
    python3 "$test_script"
    completed=$((completed + 1))
done

if [[ "$completed" -eq 0 ]]; then
    echo "No guard selftests registered in $repo_root"
else
    echo "$completed guard selftests completed"
fi
