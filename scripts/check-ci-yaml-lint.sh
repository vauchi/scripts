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
#   VCI04  side-effecting merge/main jobs must reject schedules before
#          testing the branch. Scheduled pipelines run on the default branch,
#          so a branch-only rule also matches cron pipelines.
#   VCI05  a repo including rust-base.yml that defines its own
#          `workflow: rules:` but no auto-cancel policy of its own must
#          keep the default branch out of auto-cancel. Its rules list replaces the template's, which
#          carries that guard, while the template's interruptible policy
#          stays; a merge then cancels main pipelines another repo's
#          release waits on (#632).
# Suppress per job with `# vci02-ok: <why>` / per line with
# `# vci03-ok: <why>` / `# vci04-ok: <why>` / in the workflow block with
# `# vci05-ok: <why>`.
# Rule pages: _private/docs/lint-errors/vci02-*.md … vci05-*.md
# Self-test: scripts/tests/check-ci-yaml-lint.test.sh
# Called by: pre-commit (staged *.gitlab-ci.yml, ci-templates/*.yml)

set -euo pipefail

VIOLATIONS=0

check_file() {
    file="$1"
    # POSIX awk (BusyBox-safe): block state machine keyed on top-level
    # yml keys; VCI03 evaluated per line.
    if ! awk '
        function side_effect_job(name) {
            return name == ".main-only" || name == ".mr-or-main" ||
                name == ".auto-tag" || name == ".release-trigger-multiple" ||
                name == ".trigger-on-merge" || name == ".trigger-parallel" ||
                name == ".badges-pages" || name == ".github-mirror" ||
                name == "auto-tag:version" || name == "deploy:trigger" ||
                name == "pages" || name == "github-mirror" ||
                name == "promote:latest" || name == "promote:docker:latest" ||
                name ~ /^publish:package:/
        }
        function flush() {
            if (top != "" && has_ext && has_bs && !has_ref && !ok2) {
                printf "  %s:%d: VCI02: job \"%s\" extends a template but replaces its before_script — fix: start the list with !reference [<template>, before_script] (or annotate # vci02-ok: <why>). [_private/docs/lint-errors/vci02-before-script-override.md]\n", FILENAME, bs_line, top
                bad = 1
            }
            if (top_full != "" && side_effect_job(top_full) && unsafe_main && !ok4) {
                printf "  %s:%d: VCI04: side-effect job \"%s\" matches the default branch before excluding schedules — fix: put `if: $CI_PIPELINE_SOURCE == \"schedule\"` + `when: never` before the branch rule (or annotate # vci04-ok: <why>). [_private/docs/lint-errors/vci04-schedule-before-branch.md]\n", FILENAME, main_line, top_full
                bad = 1
            }
        }
        /^[^ \t#][^:]*:/ {
            flush()
            in_wf = ($0 ~ /^workflow:/)
            top_full = $0; sub(/:[ \t]*(#.*)?$/, "", top_full)
            top = top_full; sub(/:.*/, "", top)
            has_ext = 0; has_bs = 0; has_ref = 0; ok2 = 0; ok4 = 0
            schedule_rule = 0; schedule_never = 0; unsafe_main = 0; main_line = 0
        }
        /rust-base\.yml/ { rust_base = 1 }
        in_wf && /vci05-ok/ { ok5 = 1 }
        in_wf && /^[ \t]+rules:/ { wf_rules = 1; wf_line = NR }
        in_wf && /on_new_commit:[ \t]*none/ { wf_none = 1 }
        in_wf && /^[ \t]+auto_cancel:/ {
            # The policy of the whole block sits at the first indent
            # level; an auto_cancel inside a rule sits deeper.
            indent = $0; sub(/[^ \t].*/, "", indent)
            if (length(indent) <= 3) wf_policy = 1
        }
        /vci02-ok/  { ok2 = 1 }
        /vci04-ok/  { ok4 = 1 }
        /^[ \t]+extends:/        { has_ext = 1 }
        /^[ \t]+before_script:/  { has_bs = 1; bs_line = NR }
        /!reference \[[^]]*before_script[^]]*\]/ { has_ref = 1 }
        /^[ \t]+-[ \t]+if:/ {
            schedule_rule = ($0 ~ /CI_PIPELINE_SOURCE[ \t]*==[ \t]*["\047]schedule["\047]/ &&
                $0 !~ /&&|\|\|/)
        }
        schedule_rule && /^[ \t]+when:[ \t]+never([ \t]|$)/ {
            schedule_never = 1
            schedule_rule = 0
        }
        /CI_COMMIT_BRANCH/ && (/CI_DEFAULT_BRANCH/ || /["\047]main["\047]/) {
            if (!schedule_never) {
                unsafe_main = 1
                main_line = NR
            }
        }
        /git[ \t]+(pull|fetch|checkout|reset|push)/ && /\|\|[ \t]*(true|:)([ \t]|$)/ && !/vci03-ok/ {
            printf "  %s:%d: VCI03: || true swallows a state-changing git failure in CI (job continues on stale state) — fix: let git fail the job; prefer fetch + reset --hard over pull (or annotate # vci03-ok: <why>). [_private/docs/lint-errors/vci03-or-true-in-ci.md]\n", FILENAME, NR
            bad = 1
        }
        END {
            flush()
            if (wf_rules && !wf_none && rust_base && !wf_policy && !ok5) {
                printf "  %s:%d: VCI05: own workflow rules drop the default-branch auto-cancel guard — fix: add `- if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH` with `auto_cancel: on_new_commit: none` before the source rules (or annotate # vci05-ok: <why>). [_private/docs/lint-errors/vci05-workflow-rules-drop-main-guard.md]\n", FILENAME, wf_line
                bad = 1
            }
            exit bad
        }
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
