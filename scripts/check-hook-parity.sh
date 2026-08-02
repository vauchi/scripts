#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Validate that Claude, Codex, and Kimi route through one canonical hook set.
# Informational by default; --strict makes configuration drift fail the check.
#
# Codex and Claude register their hooks in-repo, so the checks below see them.
# Kimi does not: it reads only ~/.kimi-code/config.toml and has no project-level
# config mechanism, so the repo's .kimi-code/config.toml is inert documentation.
# Checking only that file reported "all three use canonical shared hooks" while
# Kimi in fact had zero registrations and ran the workspace with no guardrails
# at all. The user-config check below is the part that can actually fail.

set -euo pipefail

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

# Kimi's actual wiring lives outside the repo. Verify every mode the canonical
# adapter dispatches is registered there — a partial registration is the silent
# failure this check exists to catch, so compare modes rather than count lines.
KIMI_USER_CONFIG="${KIMI_CODE_HOME:-$HOME/.kimi-code}/config.toml"
if [[ ! -f "$KIMI_USER_CONFIG" ]]; then
    # CI and fresh checkouts have no user config; absence is not drift.
    echo "hook-routing: note - ${KIMI_USER_CONFIG/#$HOME/\~} absent, Kimi wiring unverified"
elif [[ -f "$CANONICAL" ]]; then
    # `|| true`: grep exits 1 on no match, and under `set -e` that aborts the
    # whole check silently — the same class of invisible pass being fixed here.
    MODES=$(sed -n '/case "\$MODE" in/,/^esac/p' "$CANONICAL" \
        | grep -oE '^[[:space:]]+[a-z-]+\)' | tr -d ' )' | sort -u || true)
    MISSING=""
    for mode in $MODES; do
        grep -q "adapter\.sh\" $mode\b\|adapter\.sh $mode\b" "$KIMI_USER_CONFIG" \
            || MISSING="$MISSING $mode"
    done
    if [[ -z "$MODES" ]]; then
        problem "could not read dispatch modes from ${CANONICAL#"$ROOT/"}"
    elif [[ -n "$MISSING" ]]; then
        problem "${KIMI_USER_CONFIG/#$HOME/\~} does not register:${MISSING} - Kimi runs without those guardrails"
    fi
fi

if [[ "$DRIFT" -eq 0 ]]; then
    echo "hook-routing: Claude, Codex, and Kimi use canonical shared hooks."
    exit 0
fi

echo "hook-routing: configuration drift detected."
[[ "$STRICT" -eq 1 ]] && exit 1
exit 0
