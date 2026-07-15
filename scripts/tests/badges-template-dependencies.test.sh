#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEMPLATE="$ROOT/ci-templates/badges.yml"
failures=0

require_template_line() {
    local expected="$1"
    if ! grep -Fqx "    - $expected" "$TEMPLATE"; then
        printf 'FAIL: badges template missing `%s`\n' "$expected" >&2
        failures=$((failures + 1))
    fi
}

require_template_line \
    'fetch_vauchi_script scripts/ci/generate-badges.sh scripts/ci/generate-badges.sh'
require_template_line \
    'fetch_vauchi_script scripts/lib/common.sh scripts/lib/common.sh'
require_template_line 'scripts/ci/generate-badges.sh public/badges'

if [[ "$failures" -ne 0 ]]; then
    exit 1
fi

echo "PASS: badge runtime dependencies preserve their repository layout"
