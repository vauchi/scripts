#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
hook=${HOOK:-$root/hooks/pre-push}
branch=$(awk '
    /^        e2e\)$/ { found = 1 }
    found { print }
    found && /^            ;;$/ { exit }
' "$hook")
[ -n "$branch" ] || { echo 'FAIL: E2E has no binary-directory default in the hook' >&2; exit 1; }

check_default() {
    local expected=$1
    shift
    local got
    got=$("$@" bash -eu -c '
        REPO_ROOT="/fixture/work space/e2e"
        TEST_CMD=()
        eval "case e2e in $1 esac"
        bash -eu -c '\''printf "%s" "$E2E_BIN_DIR"'\''
    ' _ "$branch")
    [ "$got" = "$expected" ] || { printf 'FAIL: expected %s, got %s\n' "$expected" "$got" >&2; exit 1; }
}

check_default '/fixture/work space/e2e/.smoke-bin' env -u E2E_BIN_DIR
check_default '/fixture/work space/e2e/.smoke-bin' env E2E_BIN_DIR=
check_default '/custom/binaries with spaces' env E2E_BIN_DIR='/custom/binaries with spaces'
echo 'pre-push-e2e-bin-dir: 3 passed'
