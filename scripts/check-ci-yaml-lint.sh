#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI-yaml lint — deterministic checks for GitLab CI configuration
# mistakes that repeatedly shipped and failed later:
#   VCI02  job extends: a template AND declares its own before_script
#          without !reference — GitLab merges by REPLACING list keys,
#          silently dropping every template setup/cleanup step
#          (reasoning-error archive E23).
#   VCI03  `|| true` (or `|| :`) guarding state-changing git in CI —
#          the job continues green against stale state
#          (reasoning-error log L26: shallow-clone pull no-op'd).
# Suppress per job with `# vci02-ok: <why>` / per line with
# `# vci03-ok: <why>`.
# Rule pages: _private/docs/lint-errors/vci02-*.md, vci03-*.md
# Self-test: scripts/tests/check-ci-yaml-lint.test.sh
# Called by: pre-commit (staged *.gitlab-ci.yml, ci-templates/*.yml)

set -euo pipefail

VIOLATIONS=0

check_file() {
    file="$1"
    # POSIX awk (BusyBox-safe): block state machine keyed on top-level
    # yml keys; VCI03 evaluated per line.
    if ! awk '
        function flush() {
            if (top != "" && has_ext && has_bs && !has_ref && !ok2) {
                printf "  %s:%d: VCI02: job \"%s\" extends a template but replaces its before_script — fix: start the list with !reference [<template>, before_script] (or annotate # vci02-ok: <why>). [_private/docs/lint-errors/vci02-before-script-override.md]\n", FILENAME, bs_line, top
                bad = 1
            }
        }
        /^[^ \t#][^:]*:/ {
            flush()
            top = $0; sub(/:.*/, "", top)
            has_ext = 0; has_bs = 0; has_ref = 0; ok2 = 0
        }
        /vci02-ok/  { ok2 = 1 }
        /^[ \t]+extends:/        { has_ext = 1 }
        /^[ \t]+before_script:/  { has_bs = 1; bs_line = NR }
        /!reference \[[^]]*before_script[^]]*\]/ { has_ref = 1 }
        /git[ \t]+(pull|fetch|checkout|reset|push)/ && /\|\|[ \t]*(true|:)([ \t]|$)/ && !/vci03-ok/ {
            printf "  %s:%d: VCI03: || true swallows a state-changing git failure in CI (job continues on stale state) — fix: let git fail the job; prefer fetch + reset --hard over pull (or annotate # vci03-ok: <why>). [_private/docs/lint-errors/vci03-or-true-in-ci.md]\n", FILENAME, NR
            bad = 1
        }
        END { flush(); exit bad }
    ' "$file"; then
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
}

if [[ $# -eq 0 ]]; then
    echo "Usage: check-ci-yaml-lint.sh <file.yml> [...]" >&2
    exit 2
fi

for f in "$@"; do
    [[ -f "$f" ]] || continue
    check_file "$f"
done

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo ""
    printf 'FAILED: %d CI yml file(s) with configuration hazards.\n' "$VIOLATIONS"
    exit 1
fi
