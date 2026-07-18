#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VRT01 (coverage) — positive gate on test coverage. Parses the line-rate from
# a Cobertura report (produced by `just cov <repo>`) and ratchets it UPWARD:
# a merge may never drop coverage below the committed baseline, and every gain
# can be locked in as the new floor — driving `vauchi-core` toward the 90% rule.
# Wraps the generic ratchet.sh primitive.
# Rule page: _private/docs/lint-errors/vrt01-ratchet.md
# Self-test: scripts/tests/check-coverage-ratchet.test.sh
# Called by: the coverage CI/metrics job and `just session-end` (--tighten).
#
# Usage: check-coverage-ratchet.sh [--report FILE] [--baseline FILE]
#                                  [--label NAME] [--tighten]

set -euo pipefail

REPORT="core/cobertura.xml"
BASELINE="core/.coverage-baseline"
LABEL="coverage"
TIGHTEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --report)   REPORT="$2"; shift 2 ;;
        --baseline) BASELINE="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        --tighten)  TIGHTEN="--tighten"; shift ;;
        *) echo "check-coverage-ratchet: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$REPORT" ]; then
    echo "  coverage ratchet: no report at $REPORT — skipped (run 'just cov' first)"
    exit 0
fi

# Cobertura root: <coverage ... line-rate="0.9034" ...>  (a 0..1 fraction).
rate="$(grep -oE 'line-rate="[0-9.]+"' "$REPORT" | head -1 | grep -oE '[0-9.]+' || true)"
if [ -z "$rate" ]; then
    echo "check-coverage-ratchet: could not parse line-rate from $REPORT" >&2
    exit 2
fi
pct="$(awk -v r="$rate" 'BEGIN{printf "%.2f", r * 100}')"

# shellcheck disable=SC2086
exec "$SCRIPT_DIR/ratchet.sh" \
    --baseline "$BASELINE" --direction up --current "$pct" --label "$LABEL" $TIGHTEN
