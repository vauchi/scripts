#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# resource-group-reset.sh — Detect and cancel stuck jobs in ios-spm-v*
# and macos-spm-v* resource groups on a nightly schedule.
#
# Background
# ----------
# The ios/macos CI pipelines use `resource_group: ios-spm-v<N>` (and
# `macos-spm-v<N>`) to serialise simulator / SPM cache access on the
# shared self-hosted mac runners. A recurring GitLab bug (observed on
# 2026-04-11, 2026-04-19 twice, 2026-04-21) is that cancelled jobs do
# not always release their resource_group lock, leaving subsequent
# jobs wedged in `waiting_for_resource` indefinitely. The manual
# workaround has been to rename the group to a new version (v4 → v5
# → v6), but that requires a human to notice + push a commit.
#
# This script automates the "notice + cancel" half:
#
#   1. For each of the ios / macos projects, list currently `running`
#      and `pending` jobs.
#   2. For each such job, fetch its details — GitLab's bulk jobs
#      endpoint omits `resource_group`, so we need the per-job call.
#   3. If the job's resource_group matches `ios-spm-v*` / `macos-spm-v*`
#      AND the job has been running longer than STUCK_THRESHOLD_SECS,
#      treat it as stuck.
#   4. With `--execute`, POST cancel. Without, log what *would* be
#      cancelled.
#
# The script does NOT auto-bump the resource_group version — that's a
# code change that still requires human review (see runner-runbook.md
# § Resource-group poison lock).
#
# Usage
# -----
#   ./resource-group-reset.sh [--execute]
#
# Env:
#   PROJECT_ACCESS_TOKEN  Required. Must have `api` scope on both
#                         ios and macos projects.
#   STUCK_THRESHOLD_SECS  Default 7200 (2h). Jobs running longer than
#                         this are considered stuck.
#   DRY_RUN               If set (anything non-empty) — same as
#                         omitting --execute.
#
# Exit codes:
#   0   ran cleanly, whether or not anything was cancelled.
#   1   missing token / arg error.
#   2   GitLab API call failed in a way that blocks the check.

set -euo pipefail

# Project IDs — resolve via GitLab API once per update, hard-code to
# avoid a name-to-id lookup on every scheduled run.
IOS_PROJECT_ID=77813130
MACOS_PROJECT_ID=80096065

GITLAB_API="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
STUCK_THRESHOLD_SECS="${STUCK_THRESHOLD_SECS:-7200}"
EXECUTE=false

for arg in "$@"; do
    case "$arg" in
        --execute) EXECUTE=true ;;
        --dry-run) EXECUTE=false ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

if [ -n "${DRY_RUN:-}" ]; then
    EXECUTE=false
fi

if [ -z "${PROJECT_ACCESS_TOKEN:-}" ]; then
    echo "ERROR: PROJECT_ACCESS_TOKEN not set" >&2
    exit 1
fi

# Seconds since epoch for GitLab's ISO-8601 `created_at`. python3 is
# already required here and parses it identically on alpine and macOS,
# where `date -d` differs between BusyBox, GNU and BSD (VSH10).
_to_epoch() {
    python3 -c 'import datetime, sys
print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"
}

_now() { date -u +%s; }

# Prints the body of a GitLab API path; on any other status than 200 it
# names the status on stderr and fails, so callers keep their own
# fallback without losing the reason (VSH13).
gitlab_get() {
    local path="$1" body status
    body=$(mktemp)
    status=$(curl --silent --show-error -o "$body" -w '%{http_code}' \
        --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
        "${GITLAB_API}/${path}") || status="000"
    if [ "$status" != "200" ]; then
        echo "  WARNING: GitLab API ${path} returned HTTP ${status}" >&2
        rm -f "$body"
        return 1
    fi
    cat "$body"
    rm -f "$body"
}

CANCEL_COUNT=0
SKIP_COUNT=0
PROJECTS_SCANNED=0

scan_project() {
    local project_id="$1"
    local prefix="$2"
    local name
    name=$(gitlab_get "projects/${project_id}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("path","?"))' 2>/dev/null) || name="?"

    echo "=== Scanning ${name} (id ${project_id}) for ${prefix}* resource groups ==="
    PROJECTS_SCANNED=$((PROJECTS_SCANNED + 1))

    local page=1
    local now
    now=$(_now)

    # GitLab caps per_page at 100 — paginate until we see no active-state
    # jobs. `scope[]` filters are ORed; we only care about live states.
    while :; do
        local jobs_json
        jobs_json=$(gitlab_get "projects/${project_id}/jobs?scope[]=running&scope[]=pending&scope[]=waiting_for_resource&per_page=100&page=${page}") || {
            echo "  WARNING: jobs list page ${page} failed — stopping scan" >&2
            return 2
        }

        # Empty JSON array = done paginating.
        if [ "$jobs_json" = "[]" ] || [ -z "$jobs_json" ]; then
            break
        fi

        local job_rows
        # Parse errors stay on stderr: a silenced parser here reported
        # zero jobs on every run from ce521ea until vauchi/private#27.
        job_rows=$(printf '%s' "$jobs_json" | python3 -c '
import json, sys
for job in json.load(sys.stdin):
    print(job["id"], job.get("status", "?"), job.get("created_at", ""), job.get("name", ""), sep="\t")
' || true)

        if [ -z "$job_rows" ]; then
            break
        fi

        while IFS=$'\t' read -r job_id status created_at job_name; do
            [ -z "$job_id" ] && continue

            # Per-job detail includes resource_group (bulk endpoint doesn't).
            local detail
            detail=$(gitlab_get "projects/${project_id}/jobs/${job_id}") || {
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            }

            local resource_group
            resource_group=$(printf '%s' "$detail" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("resource_group") or "")
' || true)

            case "$resource_group" in
                ${prefix}*) ;;  # matches — continue
                *) SKIP_COUNT=$((SKIP_COUNT + 1)); continue ;;
            esac

            # An unreadable age must never count as stuck: with --execute
            # that would cancel a job we know nothing about.
            local created_epoch age
            created_epoch=$(_to_epoch "$created_at" 2>/dev/null) || {
                echo "  SKIP job ${job_id} (${job_name}) — ${status}, created_at '${created_at}' does not parse"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            }
            age=$((now - created_epoch))

            if [ "$age" -lt "$STUCK_THRESHOLD_SECS" ]; then
                echo "  SKIP job ${job_id} (${job_name}) — ${status}, age ${age}s < ${STUCK_THRESHOLD_SECS}s"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            echo "  STUCK job ${job_id} (${job_name}) — ${status}, age ${age}s, rg=${resource_group}"
            if $EXECUTE; then
                if curl --silent --fail --request POST \
                    --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
                    "${GITLAB_API}/projects/${project_id}/jobs/${job_id}/cancel" \
                    >/dev/null 2>&1; then
                    echo "    cancelled"
                    CANCEL_COUNT=$((CANCEL_COUNT + 1))
                else
                    echo "    WARNING: cancel failed (API error)" >&2
                fi
            else
                echo "    dry-run — would cancel (use --execute to act)"
            fi
        done <<< "$job_rows"

        page=$((page + 1))
    done
}

scan_project "$IOS_PROJECT_ID"   "ios-spm-v"
scan_project "$MACOS_PROJECT_ID" "macos-spm-v"

echo ""
echo "=== resource-group-reset summary ==="
echo "  projects scanned:      ${PROJECTS_SCANNED}"
echo "  jobs skipped (young/other rg): ${SKIP_COUNT}"
if $EXECUTE; then
    echo "  jobs cancelled:        ${CANCEL_COUNT}"
else
    echo "  jobs that would cancel: ${CANCEL_COUNT} (dry-run)"
fi

exit 0
