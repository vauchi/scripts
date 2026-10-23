#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI lint for the pre-push hook: lints the CI files a branch changes —
# .gitlab-ci.yml and its `local:` includes. Kept apart from pre-push so
# its tests run it against real repos (private#779).
#
# Usage: ci-lint.sh <repo-root>     Exit: 0 clean or nothing to lint, 1 fail.
# Self-test: scripts/tests/pre-push-ci-lint.test.sh
set -uo pipefail

REPO_ROOT="${1:?repository root required}"
HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_ROOT/.gitlab-ci.yml" ]]; then
    # The top file and its `local:` includes: core keeps most of its CI in
    # ci/*.yml, and an include-only change used to go unchecked (#779).
    if ! CI_CHANGED=$(sh "$HOOK_DIR/../scripts/check-ci-local-includes.sh" "$REPO_ROOT" changed); then
        echo "FAILED: could not list the CI files changed since origin/main."
        exit 1
    fi
    if [[ -n "$CI_CHANGED" ]]; then
        echo ""
        echo "[0] Validating CI config: $(printf '%s ' $CI_CHANGED)"
        # Parsed locally first: server lint reads main's copy of every
        # include, so it never sees a syntax error in one this push edits.
        if ! (cd "$REPO_ROOT" && sh "$HOOK_DIR/../scripts/check-ci-yaml-parse.sh" $CI_CHANGED); then
            echo ""
            echo "FAILED: CI config does not parse (above)."
            exit 1
        fi
        echo "  local YAML parse OK"
        if command -v glab &>/dev/null; then
            # Server lint resolves `local:` includes from the default
            # branch, so it judges what this push carries only while every
            # include is on main unchanged. Skipping it for any `local:`
            # include let core!1945 out with two YAML errors (private#779).
            CI_SERVER_LINT=1
            if grep -qE '^[[:space:]]*-[[:space:]]*local:' "$REPO_ROOT/.gitlab-ci.yml"; then
                includes_rc=0
                sh "$HOOK_DIR/../scripts/check-ci-local-includes.sh" "$REPO_ROOT" ||
                    includes_rc=$?
                case "$includes_rc" in
                    0) ;;
                    3)
                        CI_SERVER_LINT=0
                        echo "  server lint skipped — it would read main's copy of an include"
                        echo "  this push adds or edits; the local parse above covers it"
                        if ! sh "$HOOK_DIR/../scripts/check-ci-yaml-structure.sh" \
                            "$REPO_ROOT/.gitlab-ci.yml"; then
                            echo ""
                            echo "FAILED: CI config has a structural defect (above)."
                            exit 1
                        fi
                        ;;
                    *)
                        echo ""
                        echo "FAILED: one or more local: includes point to missing files."
                        exit 1
                        ;;
                esac
            fi
            if [ "$CI_SERVER_LINT" = 0 ]; then
                :
            elif ! CI_LINT_OUT=$(glab ci lint "$REPO_ROOT/.gitlab-ci.yml" 2>&1); then
                # `glab ci lint` POSTs to the project's lint endpoint, so a
                # token without permission there fails exactly like a broken
                # config. Reporting 403 as "CI config is invalid" blocks every
                # push in repos that use `project:` includes, for a reason
                # that has nothing to do with the config (observed on tui,
                # project 77874360). Separate the two verdicts.
                # Key on auth vocabulary, or on a status code in HTTP
                # response framing (`: 403 {`). A bare `40[13]` would also
                # match a digit inside a validation message and silently
                # excuse a real config error as an auth failure.
                if printf '%s' "$CI_LINT_OUT" |
                    grep -qE 'invalid_token|Token is expired|insufficient_scope|Forbidden|Unauthorized|:[[:space:]]*40[13][[:space:]{]'; then
                    echo "  server lint unavailable — this is an auth/permission"
                    echo "  failure, NOT a verdict on the config:"
                    printf '%s\n' "$CI_LINT_OUT" | sed 's/^/    /'
                    echo "  falling back to the local structural check"
                    if ! sh "$HOOK_DIR/../scripts/check-ci-yaml-structure.sh" \
                        "$REPO_ROOT/.gitlab-ci.yml"; then
                        echo ""
                        echo "FAILED: CI config has a structural defect (above)."
                        echo "Server lint could not run, so this is the floor —"
                        echo "fix the finding, or get lint permission for a full check."
                        exit 1
                    fi
                else
                    echo ""
                    echo "FAILED: CI config is invalid:"
                    printf '%s\n' "$CI_LINT_OUT"
                    exit 1
                fi
            else
                echo "  CI lint OK"
            fi
        fi

        # Check for jobs without runner tags.
        # All self-hosted runners have run_untagged=false — untagged jobs
        # hang forever in CI with no runner to pick them up.
        # Safe to skip: extends: (inherits tags from template), trigger:
        # (runs on GitLab infra), no script: (template override via include:).
        UNTAGGED=$(awk '
        /^[^[:space:]#%-]/ && /:/ {
            if (job != "" && has_script && !has_tags && !has_extends && !has_trigger && !is_reserved && !is_hidden)
                print "  " job
            job = $0
            sub(/:[[:space:]].*$/, "", job)
            sub(/:$/, "", job)
            has_tags = 0; has_extends = 0; has_script = 0; has_trigger = 0
            is_reserved = (job ~ /^(stages|variables|include|workflow|default|image|before_script|after_script|services|cache)$/)
            is_hidden = (job ~ /^\./)
        }
        /^[[:space:]]+tags:/ { has_tags = 1 }
        /^[[:space:]]+extends:/ { has_extends = 1 }
        /^[[:space:]]+script:/ { has_script = 1 }
        /^[[:space:]]+trigger:/ { has_trigger = 1 }
        END {
            if (job != "" && has_script && !has_tags && !has_extends && !has_trigger && !is_reserved && !is_hidden)
                print "  " job
        }' "$REPO_ROOT/.gitlab-ci.yml")

        if [[ -n "$UNTAGGED" ]]; then
            echo ""
            echo "FAILED: CI jobs without runner tags (will hang — all runners require tags):"
            echo "$UNTAGGED"
            echo ""
            echo "Add tags: [docker] for container jobs, tags: [linux] for shell jobs."
            exit 1
        fi
        echo "  Runner tags OK"
    fi
fi
