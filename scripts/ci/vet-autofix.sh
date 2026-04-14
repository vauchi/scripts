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
# remaining exemptions (repo-specific deps) and push a fix commit.
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

    # Regenerate exemptions
    if ! cargo vet ${VET_FLAGS[@]+"${VET_FLAGS[@]}"} regenerate exemptions 2>&1; then
        echo "FATAL: 'cargo vet regenerate exemptions' failed"
        echo "  This usually means a crate needs an audit, not just an exemption."
        echo "  Check cargo vet output above for details."
        exit 1
    fi
    cargo vet ${VET_FLAGS[@]+"${VET_FLAGS[@]}"} fmt 2>&1

    # Verify the fix
    if ! cargo vet ${VET_FLAGS[@]+"${VET_FLAGS[@]}"} 2>&1; then
        echo "FATAL: cargo vet still failing after regeneration"
        echo "  Exemption regeneration was not sufficient. Manual intervention required."
        exit 1
    fi
    echo "Auto-fix succeeded — cargo vet now passes"
fi

# ============================================================
# Step 4: Commit and push changes (default branch only)
# ============================================================

if git diff --quiet supply-chain/ 2>/dev/null; then
    echo "No exemption file changes to commit"
    exit 0
fi

echo ""
echo "--- Exemption changes ---"
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
git config user.email "noreply@vauchi.app"
git remote set-url origin "https://vauchi-gitlab-runner:${PROJECT_ACCESS_TOKEN}@gitlab.com/${CI_PROJECT_PATH}.git"

# Commit first, then fetch + rebase to avoid non-fast-forward failures.
# Rebase requires a clean working tree, so the commit must happen before
# the rebase (not after). If rebase conflicts (unlikely for supply-chain-only
# changes), abort and fail — manual intervention required.
git add supply-chain/
git commit -m "tidy: auto-sync cargo-vet exemptions

Triggered by dependency update on ${CI_DEFAULT_BRANCH}.
Source: ${SYNC_FROM:+project ${SYNC_FROM} (core) + }local regeneration"

git fetch origin "${CI_DEFAULT_BRANCH}" 2>/dev/null || true
if ! git rebase "origin/${CI_DEFAULT_BRANCH}" 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    echo "FATAL: rebase conflict while pushing exemption update — manual intervention required"
    exit 1
fi

git push origin "HEAD:${CI_DEFAULT_BRANCH}"

echo "Exemption updates committed and pushed to ${CI_DEFAULT_BRANCH}"
