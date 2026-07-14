#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-no-allow-direct.sh"

pass=0
fail=0

assert_exit() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — expected %s, got %s\n' \
            "$name" "$expected" "$actual" >&2
        fail=$((fail + 1))
    fi
}

run_fixture() {
    local content="$1"
    local path="${2:-src/runner.rs}"
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/$(dirname "$path")"
    printf '%s\n' "$content" > "$root/$path"

    set +e
    "$SCRIPT" "$root" >/dev/null 2>&1
    result=$?
    set -e
    rm -rf "$root"
}

run_fixture 'command.env_remove("VAUCHI_ALLOW_DIRECT");'
assert_exit "explicit removal is allowed" 0 "$result"

run_fixture 'command.env("VAUCHI_ALLOW_DIRECT", "1");'
assert_exit "Rust environment injection is rejected" 1 "$result"

run_fixture 'extra_env.insert("VAUCHI_ALLOW_DIRECT".to_string(), "1".to_string());'
assert_exit "Rust map injection is rejected" 1 "$result"

run_fixture 'VAUCHI_ALLOW_DIRECT=1 vauchi sync' 'scripts/run.sh'
assert_exit "shell environment injection is rejected" 1 "$result"

run_fixture 'extra_env.insert("VAUCHI_ALLOW_DIRECT".to_string(), "1".to_string());' \
    'src/device/tests.rs'
assert_exit "test fixture injection is allowed" 0 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct: true };' \
    'tests/it/transport_isolation.rs'
assert_exit "explicit transport-isolation test is allowed" 0 "$result"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
