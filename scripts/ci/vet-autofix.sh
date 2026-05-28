#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# vet-autofix.sh — Run cargo-vet with exemption sync and auto-fix.
#
# Before vetting, optionally syncs exemptions from a source project
# (typically vauchi-core) so that downstream repos inherit exemptions
# for shared transitive dependencies. This is more secure than blind
# regeneration — only exemptions already approved in the source project
# are propagated.
#
# When cargo-vet fails on the default branch (not MRs), regenerate
# remaining exemptions (repo-specific deps), push a fix branch, and
# create an MR with merge-when-pipeline-succeeds enabled.
#
# Usage (in .gitlab-ci.yml script section):
#   - curl -sf "$CI_API_V4_URL/projects/77957857/repository/files/scripts%2Fci%2Fvet-autofix.sh/raw?ref=main" -o vet-autofix.sh
#   - chmod +x vet-autofix.sh
#   - ./vet-autofix.sh [--regenerate-lockfile] [--sync-from=PROJECT_ID]
#
# Options:
#   --regenerate-lockfile  Remove .cargo/config.toml and regenerate
#                          Cargo.lock before vetting (for repos with
#                          path overrides, e.g. cli, tui, relay)
#   --sync-from=ID         Fetch exemptions from source project and
#                          merge missing entries before vetting.
#                          Use 77874344 for vauchi-core.
#
# Requirements:
#   - CI_COMMIT_BRANCH and CI_DEFAULT_BRANCH set by GitLab CI
#   - PROJECT_ACCESS_TOKEN variable (group-level CI variable)
#   - cargo-vet installed (caller's before_script)

set -euo pipefail

REGEN_LOCKFILE=false
SYNC_FROM=""
for arg in "$@"; do
    case "$arg" in
        --regenerate-lockfile) REGEN_LOCKFILE=true ;;
        --sync-from=*) SYNC_FROM="${arg#--sync-from=}" ;;
    esac
done

# Snapshot the pinned vauchi-core git SHA from Cargo.lock before any
# cargo invocations. If the auto-fix flow bumps it (very common — the
# whole reason this script runs is upstream churn), Step 4 surfaces
# the bump + UI-file diff in the MR description so reviewers see the
# stealth UI churn. See _private/docs/problems/2026-05-03-vet-autosync-
# stale-snapshots/README.md G2.
extract_core_sha() {
    # Match the [[package]] block for vauchi-core, then the next
    # `source = "git+...#<sha>"` line. Robust against TOML field
    # ordering since cargo writes them in a stable order.
    awk '
        /^\[\[package\]\]/ { in_pkg = 1; name = ""; src = ""; next }
        in_pkg && /^name = "vauchi-core"/ { name = "vauchi-core"; next }
        in_pkg && /^source = / { src = $0; next }
        in_pkg && /^$/ {
            if (name == "vauchi-core" && match(src, /#[0-9a-f]+"$/)) {
                sha = substr(src, RSTART + 1, RLENGTH - 2)
                print sha
                exit
            }
            in_pkg = 0
        }
    ' "${1:-Cargo.lock}"
}

OLD_CORE_SHA=$(extract_core_sha Cargo.lock 2>/dev/null || true)
echo "Pre-vet vauchi-core SHA: ${OLD_CORE_SHA:-<not pinned>}"

# ============================================================
# Step 1: Prepare lockfile
# ============================================================

if $REGEN_LOCKFILE; then
    echo "--- Regenerating Cargo.lock (removing path overrides) ---"
    rm -f .cargo/config.toml
    cargo generate-lockfile 2>&1 | tail -5
fi

# ============================================================
# Step 2: Sync exemptions from source project
# ============================================================
# Fetches config.toml from the source project via GitLab API and
# merges any exemption entries missing from the local config.
# Uses CI_JOB_TOKEN for auth (works across group projects when the
# allowlist is configured). Falls back gracefully on failure.

if [[ -n "$SYNC_FROM" ]]; then
    echo "--- Syncing exemptions from project ${SYNC_FROM} ---"

    # CI_JOB_TOKEN is auto-scoped and works for cross-project reads
    # when the source project has the caller in its CI_JOB_TOKEN allowlist.
    AUTH_HEADER=""
    if [[ -n "${CI_JOB_TOKEN:-}" ]]; then
        AUTH_HEADER="JOB-TOKEN: ${CI_JOB_TOKEN}"
    elif [[ -n "${PROJECT_ACCESS_TOKEN:-}" ]]; then
        AUTH_HEADER="PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}"
    fi

    CURL_ARGS=(--silent --fail)
    if [[ -n "$AUTH_HEADER" ]]; then
        CURL_ARGS+=(--header "$AUTH_HEADER")
    fi

    SOURCE_CONFIG=$(curl "${CURL_ARGS[@]}" \
        "${CI_API_V4_URL}/projects/${SYNC_FROM}/repository/files/supply-chain%2Fconfig.toml/raw?ref=main" \
        2>/dev/null) || {
        echo "WARNING: Could not fetch source exemptions (project ${SYNC_FROM})"
        echo "  URL: ${CI_API_V4_URL}/projects/${SYNC_FROM}/repository/files/supply-chain%2Fconfig.toml/raw?ref=main"
        echo "  Auth: ${AUTH_HEADER:+set ($(echo "$AUTH_HEADER" | cut -d: -f1))}${AUTH_HEADER:-none}"
        echo "  Continuing without sync — autofix will handle missing exemptions"
        SOURCE_CONFIG=""
    }

    if [[ -n "$SOURCE_CONFIG" ]]; then
        # Strip CRLF — GitLab API may return Windows line endings if the
        # file was committed from a Windows client. Trailing \r breaks
        # bash regex anchors and awk string comparisons.
        SOURCE_CONFIG="${SOURCE_CONFIG//$'\r'/}"

        ADDED=0
        SKIPPED=0
        CURRENT_CRATE=""
        CURRENT_VERSION=""
        CURRENT_CRITERIA=""
        CURRENT_CRITERIA_IS_ARRAY=false

        # Check if a specific crate+version exemption exists in local config.
        # Uses POSIX awk (sub, not three-argument match) so it works on
        # gawk (Linux), BWK awk (macOS), mawk, and busybox awk.
        exemption_exists() {
            local crate="$1" version="$2"
            awk -v crate="$crate" -v ver="$version" '
                /^\[\[exemptions\./ {
                    s = $0
                    sub(/^\[\[exemptions\./, "", s)
                    sub(/\]\]$/, "", s)
                    in_block = (s == crate)
                    next
                }
                in_block && /^version = / {
                    s = $0
                    sub(/^version = "/, "", s)
                    sub(/"$/, "", s)
                    if (s == ver) { found = 1; exit }
                    in_block = 0
                }
                END { exit !found }
            ' supply-chain/config.toml 2>/dev/null
        }

        flush_block() {
            if [[ -z "$CURRENT_CRATE" || -z "$CURRENT_VERSION" ]]; then
                return
            fi
            # Skip blocks with array-form criteria (e.g. criteria = ["safe-to-deploy", "safe-to-run"])
            # to avoid incorrect criteria propagation. These are rare and left to autofix.
            if $CURRENT_CRITERIA_IS_ARRAY; then
                SKIPPED=$((SKIPPED + 1))
                return
            fi
            # cargo-vet defaults to safe-to-deploy when criteria is omitted.
            local criteria="${CURRENT_CRITERIA:-safe-to-deploy}"
            if exemption_exists "$CURRENT_CRATE" "$CURRENT_VERSION"; then
                SKIPPED=$((SKIPPED + 1))
            else
                printf '\n[[exemptions.%s]]\nversion = "%s"\ncriteria = "%s"\n' \
                    "$CURRENT_CRATE" "$CURRENT_VERSION" "$criteria" \
                    >> supply-chain/config.toml
                ADDED=$((ADDED + 1))
            fi
        }

        while IFS= read -r line; do
            if [[ "$line" =~ ^\[\[exemptions\.(.+)\]\]$ ]]; then
                flush_block
                CURRENT_CRATE="${BASH_REMATCH[1]}"
                CURRENT_VERSION=""
                CURRENT_CRITERIA=""
                CURRENT_CRITERIA_IS_ARRAY=false
            elif [[ "$line" =~ ^version\ =\ \"(.+)\"$ && -n "$CURRENT_CRATE" ]]; then
                CURRENT_VERSION="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^criteria\ =\ \[.*\]$ && -n "$CURRENT_CRATE" ]]; then
                # Array-form criteria — flag for skip in flush_block
                CURRENT_CRITERIA_IS_ARRAY=true
            elif [[ "$line" =~ ^criteria\ =\ \"(.+)\"$ && -n "$CURRENT_CRATE" ]]; then
                CURRENT_CRITERIA="${BASH_REMATCH[1]}"
            fi
        done <<< "$SOURCE_CONFIG"
        flush_block

        echo "Sync: ${ADDED} exemptions added, ${SKIPPED} already present or skipped"

        if [[ "$ADDED" -gt 0 ]]; then
            cargo vet fmt 2>&1 || true
        fi
    fi
fi

# ============================================================
# Step 3: Run cargo vet
# ============================================================

VET_FLAGS=()
if ! $REGEN_LOCKFILE; then
    VET_FLAGS=(--locked)
fi

echo "--- Running cargo vet ${VET_FLAGS[*]+"${VET_FLAGS[*]}"} ---"

if cargo vet ${VET_FLAGS[@]+"${VET_FLAGS[@]}"} 2>&1; then
    echo "cargo vet passed"
    # If sync added exemptions that made vet pass, commit them
    if ! git diff --quiet supply-chain/ 2>/dev/null; then
        echo "Synced exemptions need persisting..."
    else
        exit 0
    fi
else
    echo ""
    echo "cargo vet FAILED"
    echo ""

    # Re-run cargo vet to capture human-readable failure output for diagnostics.
    # The initial run's output was already shown above; this re-run extracts the
    # specific unvetted crate lines for a cleaner summary.
    echo "--- Unvetted dependencies ---"
    cargo vet ${VET_FLAGS[@]+"${VET_FLAGS[@]}"} 2>&1 \
        | grep -E '^\s+(recommended|missing)' || true
    echo ""

    # Auto-fix only on default branch
    if [[ "${CI_COMMIT_BRANCH:-}" != "${CI_DEFAULT_BRANCH:-main}" ]]; then
        echo "Not on default branch (${CI_COMMIT_BRANCH:-unset} != ${CI_DEFAULT_BRANCH:-main}) — not auto-fixing"
        echo "Fix: add exemptions to supply-chain/config.toml, or run 'cargo vet regenerate exemptions'"
        exit 1
    fi

    echo "--- Auto-fixing on ${CI_DEFAULT_BRANCH} ---"

    # Regenerate exemptions — never pass --locked here.
    # --locked is only valid for the `cargo vet` check command, not for
    # subcommands like `regenerate` or `fmt` (cargo-vet rejects it).
    # cargo-vet's regenerate runs `cargo metadata` which may need the
    # lockfile to be fresh. If regenerate fails (stale lockfile), refresh
    # the lockfile first and retry.
    if ! cargo vet regenerate exemptions 2>&1; then
        echo "Regeneration failed — refreshing Cargo.lock and retrying..."
        cargo generate-lockfile 2>&1 | tail -5
        if ! cargo vet regenerate exemptions 2>&1; then
            echo "FATAL: 'cargo vet regenerate exemptions' failed after lockfile refresh"
            echo "  This usually means a crate needs an audit, not just an exemption."
            exit 1
        fi
    fi
    cargo vet fmt 2>&1

    # Verify the fix. For repos that use --locked, the lockfile may have
    # changed during regeneration — verify without --locked first, then
    # re-check with --locked only if the lockfile didn't change.
    if ! cargo vet 2>&1; then
        echo "FATAL: cargo vet still failing after regeneration"
        echo "  Exemption regeneration was not sufficient. Manual intervention required."
        exit 1
    fi
    echo "Auto-fix succeeded — cargo vet now passes"
fi

# ============================================================
# Step 4: Commit and create MR (default branch only)
# ============================================================

if git diff --quiet supply-chain/ Cargo.lock 2>/dev/null; then
    echo "No exemption or lockfile changes to commit"
    exit 0
fi

echo ""
echo "--- Changes ---"
git diff --stat supply-chain/ Cargo.lock

if [[ "${CI_COMMIT_BRANCH:-}" != "${CI_DEFAULT_BRANCH:-main}" ]]; then
    echo "Not on default branch — skipping push (synced exemptions will be lost after this job)"
    exit 0
fi

if [[ -z "${PROJECT_ACCESS_TOKEN:-}" ]]; then
    echo "WARNING: PROJECT_ACCESS_TOKEN not set — cannot push exemption updates"
    echo "  The vet check passed, but changes won't be persisted."
    echo "  Set PROJECT_ACCESS_TOKEN as a group-level CI variable to enable auto-push."
    exit 0
fi

git config user.name "vauchi-gitlab-runner"
git config user.email "35099472-project-access-token@users.noreply.gitlab.com"
git remote set-url origin "https://vauchi-gitlab-runner:${PROJECT_ACCESS_TOKEN}@gitlab.com/${CI_PROJECT_PATH}.git"

BRANCH="tidy/vet-autofix-$(date -u +%Y%m%d-%H%M%S)"
COMMIT_MSG="tidy: auto-sync cargo-vet exemptions

Triggered by dependency update on ${CI_DEFAULT_BRANCH}.
Source: ${SYNC_FROM:+project ${SYNC_FROM} (core) + }local regeneration"

git checkout -b "$BRANCH"
git add supply-chain/ Cargo.lock
git commit -m "$COMMIT_MSG"

NEW_CORE_SHA=$(extract_core_sha Cargo.lock 2>/dev/null || true)

# Phase 2 of `2026-05-03-vet-autosync-stale-snapshots`: when the
# lockfile bump also moved vauchi-core to a different rev,
# regenerate snapshots so consumer test fixtures stay in sync with
# the new ScreenModel shape. Emitted as a *separate* `tidy:` commit
# parented on the vet-sync commit (G4 invariant) so reviewers can
# `git show` the snapshot diff in isolation. Failures are
# non-fatal — the MR still ships with the Phase 1 warning block in
# its description.
if [[ -n "$OLD_CORE_SHA" && -n "$NEW_CORE_SHA" && "$OLD_CORE_SHA" != "$NEW_CORE_SHA" ]]; then
    REGEN_SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
    if "${REGEN_SCRIPT_DIR}/regen-snapshots.sh" "$OLD_CORE_SHA" "$NEW_CORE_SHA"; then
        if ! git diff --quiet HEAD 2>/dev/null; then
            git add -A
            REGEN_MSG="tidy: regenerate snapshots after core ${OLD_CORE_SHA:0:8}→${NEW_CORE_SHA:0:8}

Auto-regenerated by vet-autofix.sh because the cargo-vet exemption
sync also bumped vauchi-core to a rev that touched
core/vauchi-app/src/ui/. Review the snapshot diff in this commit to
confirm the new ScreenModel shape is intended.

Generated by: cargo insta test --accept --workspace
See: _private/docs/problems/2026-05-03-vet-autosync-stale-snapshots/"
            git commit -m "$REGEN_MSG"
            echo "regen-snapshots: produced changes — committed as separate tidy:"
        else
            echo "regen-snapshots: ran clean — no snapshot changes (UI shape unchanged or repo has no snapshots)"
        fi
    else
        echo "regen-snapshots: failed — MR will ship as Phase 1 (warning only) shape"
    fi
fi

git fetch origin "${CI_DEFAULT_BRANCH}" 2>/dev/null || true
if ! git rebase "origin/${CI_DEFAULT_BRANCH}" 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    echo "FATAL: rebase conflict while pushing exemption update — manual intervention required"
    exit 1
fi

git push origin "$BRANCH"

echo "Pushed branch ${BRANCH}"

# Create MR via GitLab API and enable merge-when-pipeline-succeeds
MR_BODY="Automated cargo-vet exemption sync triggered by CI on \`${CI_DEFAULT_BRANCH}\`."
MR_BODY="${MR_BODY}\n\nSource: ${SYNC_FROM:+project ${SYNC_FROM} (core) + }local regeneration."
MR_BODY="${MR_BODY}\n\nThis MR was created automatically and set to merge when pipeline succeeds."

# G2 of `2026-05-03-vet-autosync-stale-snapshots`: if the lockfile
# also bumped vauchi-core to a rev that touched UI code, append a
# warning block so reviewers see the stealth UI churn before CI
# flags missing snapshot regen. Failures here are non-fatal — the
# core MR is still useful without the warning.
NEW_CORE_SHA=$(extract_core_sha Cargo.lock 2>/dev/null || true)
if [[ -n "$OLD_CORE_SHA" && -n "$NEW_CORE_SHA" && "$OLD_CORE_SHA" != "$NEW_CORE_SHA" ]]; then
    echo "vauchi-core bumped: ${OLD_CORE_SHA:0:8} → ${NEW_CORE_SHA:0:8}"
    # vauchi/core project id (numeric) is used as the API target.
    # If unset (test runs, local invocations), skip the warning.
    CORE_PROJECT_ID="${VAUCHI_CORE_PROJECT_ID:-77874344}"
    UI_FILES=$(curl --silent --fail \
        ${PROJECT_ACCESS_TOKEN:+--header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}"} \
        "${CI_API_V4_URL}/projects/${CORE_PROJECT_ID}/repository/compare?from=${OLD_CORE_SHA}&to=${NEW_CORE_SHA}" \
        2>/dev/null \
        | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for d in data.get('diffs', []):
        path = d.get('new_path') or d.get('old_path') or ''
        if path.startswith('vauchi-app/src/ui/') or path.startswith('vauchi-app/src/notification_types'):
            print('core/' + path)
except Exception:
    pass
" 2>/dev/null || true)
    if [[ -n "$UI_FILES" ]]; then
        SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
        WARNING_BLOCK=$(printf '%s\n' "$UI_FILES" \
            | "${SCRIPT_DIR}/vet-autofix-description.sh" "$OLD_CORE_SHA" "$NEW_CORE_SHA" \
            2>/dev/null || true)
        if [[ -n "$WARNING_BLOCK" ]]; then
            MR_BODY="${MR_BODY}${WARNING_BLOCK}"
            echo "Appended UI-churn warning to MR description"
        fi
    else
        echo "vauchi-core bumped but no vauchi-app/src/ui/ files changed — no warning needed"
    fi
fi

MR_RESPONSE=$(curl --silent --fail --request POST \
    --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" \
    --data-urlencode "source_branch=${BRANCH}" \
    --data-urlencode "target_branch=${CI_DEFAULT_BRANCH}" \
    --data-urlencode "title=tidy: auto-sync cargo-vet exemptions" \
    --data-urlencode "description=${MR_BODY}" \
    --data-urlencode "remove_source_branch=true" \
    2>&1) || {
    echo "WARNING: Could not create MR — push succeeded, create MR manually"
    echo "  Branch: ${BRANCH}"
    exit 0
}

MR_IID=$(echo "$MR_RESPONSE" | grep -o '"iid":[0-9]*' | head -1 | cut -d: -f2)
MR_URL=$(echo "$MR_RESPONSE" | grep -o '"web_url":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "Created MR !${MR_IID}: ${MR_URL}"

# ============================================================
# Step 4b: Close stale predecessor vet-autofix MRs
# ============================================================
# Each CI run that detects an exemption-needing dep update opens a
# new MR. Without cleanup, stacks accumulate (observed 2026-05-28:
# two open MRs each in cli + tui, two in relay). The newest MR
# subsumes all older ones — same `cargo vet regenerate exemptions`
# output, just on a fresher commit base — so close older siblings
# rather than leaving humans to triage the stack. Non-fatal: a
# close failure leaves the old MR open (harmless) and never blocks
# the new MR's auto-merge.
if [[ -n "$MR_IID" ]]; then
    STALE_IIDS=$(curl --silent --fail \
        --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests?state=opened&per_page=100" \
        2>/dev/null \
        | NEW_MR_IID="$MR_IID" python3 -c "
import json, os, sys
new_iid = int(os.environ.get('NEW_MR_IID', '0'))
try:
    for mr in json.load(sys.stdin):
        iid = mr.get('iid')
        sb = mr.get('source_branch', '')
        if sb.startswith('tidy/vet-autofix-') and iid != new_iid:
            print(iid)
except Exception:
    pass
" 2>/dev/null || true)

    for iid in $STALE_IIDS; do
        echo "Closing superseded MR !${iid}"
        curl --silent --fail --request PUT \
            --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
            "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${iid}" \
            --data "state_event=close" \
            >/dev/null 2>&1 || echo "  (close failed for !${iid} — leaving open)"
        curl --silent --fail --request POST \
            --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
            "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${iid}/notes" \
            --data-urlencode "body=Superseded by !${MR_IID} (newer auto-sync run)." \
            >/dev/null 2>&1 || true
    done
fi

# Enable merge-when-pipeline-succeeds (auto-merge)
if [[ -n "$MR_IID" ]]; then
    curl --silent --fail --request PUT \
        --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${MR_IID}/merge" \
        --data "merge_when_pipeline_succeeds=true" \
        >/dev/null 2>&1 || {
        echo "NOTE: Could not enable auto-merge — merge MR manually"
    }
fi

echo "Exemption updates pushed to ${BRANCH} — MR will auto-merge when pipeline passes"
