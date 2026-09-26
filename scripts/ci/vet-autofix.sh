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
# When cargo-vet fails on the default branch (not MRs), regenerate the
# remaining exemptions (repo-specific deps), push a fix branch, and
# create an MR with merge-when-pipeline-succeeds enabled.
#
# INVARIANT: this job only ever touches supply-chain/. It never bumps
# Cargo.lock. Exemption sync is supply-chain housekeeping, not a
# dependency upgrade — a lockfile change means a real dependency version
# moved, which is surfaced as a loud failure for a reviewed bump MR. This
# keeps auto-sync MRs always-mergeable (previously a smuggled dep bump
# could break consumer tests and wedge the MR open forever; see the
# --regenerate-lockfile note below).
#
# Usage (in .gitlab-ci.yml script section):
#   - fetch_vauchi_script scripts/ci/vet-autofix.sh vet-autofix.sh
#   - chmod +x vet-autofix.sh
#   - ./vet-autofix.sh [--sync-from=PROJECT_ID]
#
# Options:
#   --sync-from=ID         Fetch exemptions from source project and
#                          merge missing entries before vetting.
#                          Use 77874344 for vauchi-core.
#   --regenerate-lockfile  DEPRECATED no-op (accepted for wiring compat).
#
# Requirements:
#   - CI_COMMIT_BRANCH and CI_DEFAULT_BRANCH set by GitLab CI
#   - PROJECT_ACCESS_TOKEN variable (group-level CI variable)
#   - cargo-vet installed (caller's before_script)

set -euo pipefail

SYNC_FROM=""
for arg in "$@"; do
    case "$arg" in
        --regenerate-lockfile)
            # DEPRECATED no-op. This flag used to `cargo generate-lockfile`,
            # which upgraded every registry dep and re-pinned the vauchi-core
            # git dep to its latest tip — turning a supply-chain housekeeping
            # run into an unreviewed dependency bump that broke consumer tests
            # (relay 2026-07-21: core's guardian-store 400->422 change surfaced
            # only under the regenerated lock, wedging the auto-sync MR). The
            # committed lockfile is already git/registry-sourced in CI (the
            # path-override fence is local-only), so cargo vet runs --locked
            # against it directly. Accepted-and-ignored for wiring compat.
            echo "NOTE: --regenerate-lockfile is deprecated and ignored" \
                 "(exemption sync no longer bumps Cargo.lock)" ;;
        --sync-from=*) SYNC_FROM="${arg#--sync-from=}" ;;
    esac
done

# ============================================================
# Step 1: Sync exemptions from source project
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

    CURL_ARGS=(--silent --show-error)
    if [[ -n "$AUTH_HEADER" ]]; then
        CURL_ARGS+=(--header "$AUTH_HEADER")
    fi

    SOURCE_URL="${CI_API_V4_URL}/projects/${SYNC_FROM}/repository/files/supply-chain%2Fconfig.toml/raw?ref=main"
    SOURCE_BODY=$(mktemp)
    SOURCE_STATUS=$(curl "${CURL_ARGS[@]}" -o "$SOURCE_BODY" -w '%{http_code}' "$SOURCE_URL") \
        || SOURCE_STATUS="000"
    if [[ "$SOURCE_STATUS" == "200" ]]; then
        SOURCE_CONFIG=$(cat "$SOURCE_BODY")
    else
        echo "WARNING: Could not fetch source exemptions (project ${SYNC_FROM}): HTTP ${SOURCE_STATUS}"
        echo "  URL: ${SOURCE_URL}"
        echo "  Auth: ${AUTH_HEADER:+set ($(echo "$AUTH_HEADER" | cut -d: -f1))}${AUTH_HEADER:-none}"
        echo "  Continuing without sync — autofix will handle missing exemptions"
        SOURCE_CONFIG=""
    fi
    rm -f "$SOURCE_BODY"

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
            echo "--- Pruning source-only exemptions ---"
            if ! cargo vet regenerate exemptions 2>&1; then
                echo "FATAL: could not normalize synced exemptions"
                echo "  Refusing to persist an unpruned source exemption set."
                exit 1
            fi
            cargo vet fmt 2>&1
        fi
    fi
fi

# ============================================================
# Step 2: Run cargo vet
# ============================================================
# Always --locked: exemptions are version-specific and must match the
# committed lockfile that consumers vet against. Never regenerate the
# lockfile here — a version change is a reviewed dependency bump, not
# supply-chain housekeeping (see the --regenerate-lockfile note above).

VET_FLAGS=(--locked)

echo "--- Running cargo vet ${VET_FLAGS[*]} ---"

if cargo vet "${VET_FLAGS[@]}" 2>&1; then
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
    cargo vet "${VET_FLAGS[@]}" 2>&1 \
        | grep -E '^[[:space:]]+(recommended|missing)' || true
    echo ""

    # Auto-fix only on default branch
    if [[ "${CI_COMMIT_BRANCH:-}" != "${CI_DEFAULT_BRANCH:-main}" ]]; then
        echo "Not on default branch (${CI_COMMIT_BRANCH:-unset} != ${CI_DEFAULT_BRANCH:-main}) — not auto-fixing"
        echo "Fix: add exemptions to supply-chain/config.toml, or run 'cargo vet regenerate exemptions'"
        exit 1
    fi

    echo "--- Auto-fixing on ${CI_DEFAULT_BRANCH} ---"

    # Regenerate exemptions against the committed lockfile — never pass
    # --locked here (cargo-vet rejects it on subcommands). We deliberately
    # do NOT `cargo generate-lockfile` on failure: refreshing the lock would
    # bump dependencies, which is exactly the coupling this script no longer
    # allows. If regenerate fails, a crate genuinely needs an audit (or a
    # real dependency changed) — surface it for a human, don't paper over it.
    if ! cargo vet regenerate exemptions 2>&1; then
        echo "FATAL: 'cargo vet regenerate exemptions' failed" >&2
        echo "  A crate needs an audit, or a dependency changed and needs a" >&2
        echo "  reviewed bump MR. Exemption auto-sync cannot resolve this." >&2
        exit 1
    fi
    cargo vet fmt 2>&1

    if ! cargo vet "${VET_FLAGS[@]}" 2>&1; then
        echo "FATAL: cargo vet still failing after regeneration" >&2
        echo "  Exemption regeneration was not sufficient. Manual intervention required." >&2
        exit 1
    fi
    echo "Auto-fix succeeded — cargo vet now passes"
fi

# ============================================================
# Step 3: Guard — exemption sync must never alter Cargo.lock
# ============================================================
# The invariant that keeps this job's MRs always-mergeable: a tidy: auto-sync
# only maintains supply-chain/ exemptions. If Cargo.lock drifted, a real
# dependency version changed — that belongs in a deliberate bump MR where
# consumer tests are reviewed, not smuggled under a housekeeping label (the
# failure mode that wedged relay's auto-sync MRs: a bumped core changed test
# behaviour, so test:unit failed and the MR could never auto-merge). Fail loud.
if ! git diff --quiet Cargo.lock 2>/dev/null; then
    echo "FATAL: Cargo.lock changed during exemption sync — refusing to commit." >&2
    echo "  Exemption auto-sync must not bump dependencies. Route the version" >&2
    echo "  change through a reviewed dependency-bump MR instead." >&2
    git --no-pager diff --stat Cargo.lock >&2
    exit 1
fi

# ============================================================
# Step 4: Commit and create MR (default branch only)
# ============================================================

if git diff --quiet supply-chain/ 2>/dev/null; then
    echo "No exemption changes to commit"
    exit 0
fi

echo ""
echo "--- Changes ---"
git diff --stat supply-chain/

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
git add supply-chain/
git commit -m "$COMMIT_MSG"

git fetch origin "${CI_DEFAULT_BRANCH}" 2>/dev/null || true
if ! git rebase "origin/${CI_DEFAULT_BRANCH}" 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    echo "FATAL: rebase conflict while pushing exemption update — manual intervention required"
    exit 1
fi

git push origin "$BRANCH"

echo "Pushed branch ${BRANCH}"

# Create MR via GitLab API and enable merge-when-pipeline-succeeds
printf -v MR_BODY '%s\n\n%s\n\n%s' \
    "Automated cargo-vet exemption sync triggered by CI on \`${CI_DEFAULT_BRANCH}\`." \
    "Source: ${SYNC_FROM:+project ${SYNC_FROM} (core) + }local regeneration." \
    "This MR was created automatically and set to merge when pipeline succeeds."

MR_RESPONSE=$(curl --silent --show-error --fail-with-body --request POST \
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
    echo "  GitLab said: ${MR_RESPONSE:0:300}"
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
    OPEN_MRS=$(curl --silent --show-error --fail-with-body \
        --header "PRIVATE-TOKEN: ${PROJECT_ACCESS_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests?state=opened&per_page=100") || {
        echo "  (could not list open MRs, so superseded ones stay open: ${OPEN_MRS:0:300})"
        OPEN_MRS='[]'
    }
    STALE_IIDS=$(printf '%s' "$OPEN_MRS" \
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
