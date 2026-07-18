#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VRT01 (adr066-migration) — positive gate driving the ADR-066 migration to 0.
# ADR-066 retires the ScreenModel-era types (ScreenModel, WorkflowEngine,
# UiFieldVisibility, VisibilityMode) from the shell boundary; they may survive
# temporarily in Core but must disappear from frontends. This counts remaining
# references in a frontend repo and ratchets that count DOWNWARD — a merge may
# never add new ones, and every removal becomes the new ceiling.
#
# Distinct from audit-frontend-vocab.sh (nav string literals) and
# audit-mobile-surface.sh (Mobile* types) — those count other categories and
# do NOT count these retired types, so there is no double-counting.
# Wraps the generic ratchet.sh primitive.
# Rule page: _private/docs/lint-errors/vrt01-ratchet.md
# Self-test: scripts/tests/check-adr066-migration.test.sh
# Called by: per-frontend-repo CI + `just session-end` (--tighten).
#
# Usage: check-adr066-migration.sh [--root DIR] [--baseline FILE]
#                                  [--label NAME] [--tighten]

set -euo pipefail

ROOT="."
BASELINE=""
LABEL="adr066-migration"
TIGHTEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="$2"; shift 2 ;;
        --baseline) BASELINE="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        --tighten)  TIGHTEN="--tighten"; shift ;;
        *) echo "check-adr066-migration: unknown arg '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$BASELINE" ] || BASELINE="$ROOT/.adr066-migration-baseline"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Retired ScreenModel-era types (distinctive, vauchi-specific — the generic
# 'Component'/'UserAction' are excluded to avoid matching unrelated code).
PATTERN='\b(ScreenModel|WorkflowEngine|UiFieldVisibility|VisibilityMode)\b'

# Count occurrences across source files, excluding build artifacts.
count="$(grep -rIoE "$PATTERN" "$ROOT" \
    --exclude-dir=target --exclude-dir=build --exclude-dir=node_modules \
    --exclude-dir=.git --exclude-dir=Pods --exclude-dir=DerivedData \
    2>/dev/null | wc -l | tr -d ' ')"

echo "  adr066-migration: $count retired-type reference(s) in $ROOT"

exec "$SCRIPT_DIR/ratchet.sh" \
    --baseline "$BASELINE" --direction down --current "$count" --label "$LABEL" $TIGHTEN
