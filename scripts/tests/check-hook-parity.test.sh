#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Test runner for the cross-agent hook routing validator.

set -euo pipefail

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-hook-parity.sh"
WORK="/tmp/hook-parity.test.$$"

PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT

ck() {
    if [[ "$2" == "0" ]]; then
        printf '  PASS  %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$1"
        FAIL=$((FAIL + 1))
    fi
}

fixture() {
    rm -rf "$WORK"
    mkdir -p "$WORK/.claude/hooks" "$WORK/.codex/hooks" "$WORK/.kimi-code/hooks"
    printf '#!/bin/bash\n' > "$WORK/.claude/hooks/agent-adapter.sh"
    printf 'exec "$PROJECT_DIR/.claude/hooks/agent-adapter.sh" codex "$MODE"\n' \
        > "$WORK/.codex/hooks/adapter.sh"
    printf 'bash "$PROJECT_DIR/.claude/hooks/agent-adapter.sh" kimi "$MODE"\n' \
        > "$WORK/.kimi-code/hooks/adapter.sh"
    printf 'command = "bash .kimi-code/hooks/adapter.sh pre-bash"\n' \
        > "$WORK/.kimi-code/config.toml"
    printf 'command = "/bin/bash .codex/hooks/adapter.sh pre-bash"\n' \
        > "$WORK/.codex/config.toml"
}

fixture
out=$(bash "$SCRIPT" --strict "$WORK"); code=$?
ck "canonical routing exits 0" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"
ck "canonical routing is reported" "$(grep -q 'canonical shared hooks' <<< "$out" && echo 0 || echo 1)"

rm "$WORK/.codex/hooks/adapter.sh"
bash "$SCRIPT" --strict "$WORK" >/dev/null 2>&1; code=$?
ck "missing Codex adapter fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
printf '#!/bin/bash\n' > "$WORK/.kimi-code/hooks/legacy-copy.sh"
bash "$SCRIPT" --strict "$WORK" >/dev/null 2>&1; code=$?
ck "legacy Kimi hook copy fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
printf 'command = "bash .kimi-code/hooks/legacy-copy.sh"\n' >> "$WORK/.kimi-code/config.toml"
bash "$SCRIPT" --strict "$WORK" >/dev/null 2>&1; code=$?
ck "direct Kimi hook routing fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
    printf 'check-hook-parity.test: %d passed, 0 failed\n' "$PASS"
    exit 0
fi

printf 'check-hook-parity.test: %d passed, %d FAILED\n' "$PASS" "$FAIL"
exit 1
