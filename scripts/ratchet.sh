#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ratchet.sh — generic positive-gate (ratchet) primitive. Compares a current
# metric against a committed baseline file and only allows movement toward the
# goal; every improvement can be locked in so it can never backslide.
#
# Unlike the project's static-baseline budgets (e.g. .text-literal-baseline,
# which must be lowered by hand), this auto-tightens on improvement in --tighten
# mode — the mechanic behind coverage ratchets like jest-ratchet.
#
# Two directions:
#   --direction down  budget → drive toward 0 (fail if current > baseline)
#   --direction up    climb  → drive toward a target (fail if current < baseline)
#
# Modes:
#   check (default)   fail on regression; on improvement print an advisory (CI-safe,
#                     never writes) so the baseline stays the committed floor/ceiling
#   --tighten         on improvement, write the better value back to the baseline
#                     (run locally / at session-end / pre-commit, then commit it)
#
# A missing baseline file is seeded from the current value (first run) and passes.
# Values may be integers or floats (coverage %); comparison is awk-based.
# Rule page: _private/docs/lint-errors/vrt01-ratchet.md
# Self-test: scripts/tests/ratchet.test.sh

set -euo pipefail

BASELINE=""
DIRECTION=""
CURRENT=""
LABEL="metric"
TIGHTEN=0

usage() {
    echo "Usage: ratchet.sh --baseline FILE --direction up|down --current VALUE [--label NAME] [--tighten]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline)  BASELINE="$2"; shift 2 ;;
        --direction) DIRECTION="$2"; shift 2 ;;
        --current)   CURRENT="$2"; shift 2 ;;
        --label)     LABEL="$2"; shift 2 ;;
        --tighten)   TIGHTEN=1; shift ;;
        -h|--help)   usage ;;
        *)           echo "ratchet.sh: unknown arg '$1'" >&2; usage ;;
    esac
done

[ -n "$BASELINE" ] && [ -n "$DIRECTION" ] && [ -n "$CURRENT" ] || usage
case "$DIRECTION" in up|down) ;; *) echo "ratchet.sh: --direction must be up|down" >&2; usage ;; esac
# Numeric (int or float) sanity on the current value.
printf '%s' "$CURRENT" | grep -qE '^-?[0-9]+([.][0-9]+)?$' || {
    echo "ratchet.sh: --current must be numeric (got '$CURRENT')" >&2; exit 2; }

write_baseline() {
    printf '# %s ratchet baseline (direction: %s). Auto-tightened on improvement.\n%s\n' \
        "$LABEL" "$DIRECTION" "$1" > "$BASELINE"
}

# Seed on first run.
if [ ! -f "$BASELINE" ]; then
    write_baseline "$CURRENT"
    echo "  ratchet[$LABEL]: seeded baseline at $CURRENT ($DIRECTION)"
    exit 0
fi

BASE="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | head -1 | tr -d '[:space:]')"
printf '%s' "$BASE" | grep -qE '^-?[0-9]+([.][0-9]+)?$' || {
    echo "ratchet.sh: baseline file $BASELINE must hold one number (got '$BASE')" >&2; exit 2; }

# awk truth helpers (float-safe): cmp a OP b.
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

improved=0
regressed=0
if [ "$DIRECTION" = "down" ]; then
    gt "$CURRENT" "$BASE" && regressed=1
    lt "$CURRENT" "$BASE" && improved=1
else
    lt "$CURRENT" "$BASE" && regressed=1
    gt "$CURRENT" "$BASE" && improved=1
fi

if [ "$regressed" = "1" ]; then
    echo "  ratchet[$LABEL]: FAILED — regressed $BASE → $CURRENT (must not move $([ "$DIRECTION" = down ] && echo up || echo down)). [_private/docs/lint-errors/vrt01-ratchet.md]" >&2
    exit 1
fi

if [ "$improved" = "1" ]; then
    if [ "$TIGHTEN" = "1" ]; then
        write_baseline "$CURRENT"
        echo "  ratchet[$LABEL]: tightened baseline $BASE → $CURRENT — commit $BASELINE to lock it in"
    else
        echo "  ratchet[$LABEL]: improved $BASE → $CURRENT — run with --tighten (or edit $BASELINE) to lock it in"
    fi
    exit 0
fi

echo "  ratchet[$LABEL]: at baseline ($BASE)"
exit 0
