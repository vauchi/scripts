#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Validate that Claude, Codex, and Kimi route through one canonical hook set.
# Informational by default; --strict makes configuration drift fail the check.

set -uo pipefail

STRICT=0
ROOT="."
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) ROOT="$arg" ;;
    esac
done

CANONICAL="$ROOT/.claude/hooks/agent-adapter.sh"
CODEX_ADAPTER="$ROOT/.codex/hooks/adapter.sh"
KIMI_ADAPTER="$ROOT/.kimi-code/hooks/adapter.sh"
CODEX_CONFIG="$ROOT/.codex/config.toml"
KIMI_CONFIG="$ROOT/.kimi-code/config.toml"
DRIFT=0

problem() {
    echo "hook-routing: $1"
    DRIFT=1
}

for required in \
    "$CANONICAL" \
    "$CODEX_ADAPTER" \
    "$KIMI_ADAPTER" \
    "$CODEX_CONFIG" \
    "$KIMI_CONFIG"; do
    [[ -f "$required" ]] || problem "missing ${required#"$ROOT/"}"
done

if [[ -f "$CODEX_ADAPTER" ]] \
    && ! grep -q '\.claude/hooks/agent-adapter\.sh' "$CODEX_ADAPTER"; then
    problem ".codex/hooks/adapter.sh does not route to the canonical adapter"
fi

if [[ -f "$KIMI_ADAPTER" ]] \
    && ! grep -q '\.claude/hooks/agent-adapter\.sh' "$KIMI_ADAPTER"; then
    problem ".kimi-code/hooks/adapter.sh does not route to the canonical adapter"
fi

if [[ -d "$ROOT/.kimi-code/hooks" ]]; then
    LEGACY_KIMI=$(find "$ROOT/.kimi-code/hooks" -maxdepth 1 -type f -name '*.sh' \
        ! -name 'adapter.sh' -exec basename {} \; 2>/dev/null | sort)
    if [[ -n "$LEGACY_KIMI" ]]; then
        problem "legacy copied Kimi hooks remain: $(tr '\n' ' ' <<< "$LEGACY_KIMI")"
    fi
fi

if [[ -f "$CODEX_CONFIG" ]] \
    && grep 'command = .*\.codex/hooks/' "$CODEX_CONFIG" \
        | grep -v '\.codex/hooks/adapter\.sh' >/dev/null 2>&1; then
    problem ".codex/config.toml bypasses its adapter"
fi

if [[ -f "$KIMI_CONFIG" ]] \
    && grep 'command = .*\.kimi-code/hooks/' "$KIMI_CONFIG" \
        | grep -v '\.kimi-code/hooks/adapter\.sh' >/dev/null 2>&1; then
    problem ".kimi-code/config.toml bypasses its adapter"
fi

if [[ "$DRIFT" -eq 0 ]]; then
    echo "hook-routing: Claude, Codex, and Kimi use canonical shared hooks."
    exit 0
fi

echo "hook-routing: configuration drift detected."
[[ "$STRICT" -eq 1 ]] && exit 1
exit 0
