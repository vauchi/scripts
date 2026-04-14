#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Setup CI_JOB_TOKEN Allowlists
#
# Configures cross-repo CI_JOB_TOKEN access so repos can trigger
# each other's pipelines and access packages without dedicated
# trigger tokens.
#
# Prerequisites:
#   - glab CLI authenticated (glab auth status)
#
# What this does:
#   1. Adds vauchi-platform-swift to core's job token allowlist
#      (so core CI can trigger distribution repos)
#   2. Adds core to distribution repos' allowlists (so they can
#      download packages from core)
#   3. Adds core/distribution repos to consumer app allowlists (so
#      CI can trigger app pipelines)
#   4. Adds Rust consumer repos (cli, tui, relay, e2e, linux-gtk,
#      ohttp-relay) to core's allowlist (so vet-autofix.sh --sync-from
#      can read core's supply-chain/config.toml via CI_JOB_TOKEN)
#
# Note: vauchi-platform-kotlin is archived — Maven AAR published from core.
#
# After running:
#   - Replace $ANDROID_APP_TRIGGER_TOKEN / $IOS_APP_TRIGGER_TOKEN
#     usage in CI with $CI_JOB_TOKEN
#   - Remove per-project trigger tokens from CI/CD settings
#
# Usage:
#   ./setup-job-token-allowlist.sh [--dry-run]

set -euo pipefail

GROUP="vauchi"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY RUN] No changes will be made"
    echo ""
fi

# Verify glab is authenticated
if ! glab auth status &>/dev/null; then
    echo "ERROR: glab is not authenticated"
    echo "  Run: glab auth login"
    exit 1
fi
echo "✓ glab authenticated"
echo ""

# Get project ID by path
get_project_id() {
    local path="$1"
    glab api "projects/$(echo "$path" | sed 's/\//%2F/g')" | jq -r '.id'
}

# Add project to another project's job token allowlist
add_to_allowlist() {
    local target_path="$1"
    local allowed_path="$2"
    local target_id allowed_id

    target_id=$(get_project_id "$target_path")
    allowed_id=$(get_project_id "$allowed_path")

    echo "  ${allowed_path} → ${target_path}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY RUN] Would add project ${allowed_id} to project ${target_id} allowlist"
        return
    fi

    response=$(glab api "projects/${target_id}/job_token_scope/allowlist" \
        --method POST \
        --raw-field "target_project_id=${allowed_id}" 2>&1) || true

    if echo "$response" | grep -q 'project_id'; then
        echo "    ✓ Added"
    elif echo "$response" | grep -qi "already"; then
        echo "    ✓ Already in allowlist"
    else
        echo "    ✗ Failed: $response"
    fi
}

# List current allowlist for a project
show_allowlist() {
    local path="$1"
    local project_id
    project_id=$(get_project_id "$path")

    echo "  ${path}:"
    glab api "projects/${project_id}/job_token_scope/allowlist" 2>/dev/null | jq -r '.[].path_with_namespace' | \
        sed 's/^/    - /' || echo "    (empty)"
}

echo "=== CI_JOB_TOKEN Allowlist Setup ==="
echo ""

# ── Show current state ──────────────────────────────────────────
echo "── Current allowlists ──"
show_allowlist "${GROUP}/core"
show_allowlist "${GROUP}/vauchi-platform-swift"
show_allowlist "${GROUP}/android"
show_allowlist "${GROUP}/ios"
show_allowlist "${GROUP}/macos"
echo ""

# ── Step 1: Core can be accessed by distribution repos ──────────
# vauchi-platform-kotlin is archived — Maven AAR published from core directly.
echo "── Step 1: Core ← Distribution repos (package access) ──"
add_to_allowlist "${GROUP}/core" "${GROUP}/vauchi-platform-swift"
echo ""

# ── Step 2: Distribution repos can be triggered by core ─────────
echo "── Step 2: Distribution repos ← Core (trigger access) ──"
add_to_allowlist "${GROUP}/vauchi-platform-swift" "${GROUP}/core"
echo ""

# ── Step 3: App repos can be triggered by distribution/core ──────
echo "── Step 3: App repos ← Core/Distribution (trigger access) ──"
add_to_allowlist "${GROUP}/android" "${GROUP}/core"
add_to_allowlist "${GROUP}/ios" "${GROUP}/vauchi-platform-swift"
add_to_allowlist "${GROUP}/macos" "${GROUP}/vauchi-platform-swift"
echo ""

# ── Step 4: Core can be read by Rust consumer repos (vet-sync) ───
# vet-autofix.sh --sync-from fetches core's supply-chain/config.toml
# via CI_JOB_TOKEN. Consumer repos need core in their allowlist so
# their CI_JOB_TOKEN can read core's files.
echo "── Step 4: Core ← Rust consumers (vet exemption sync) ──"
add_to_allowlist "${GROUP}/core" "${GROUP}/cli"
add_to_allowlist "${GROUP}/core" "${GROUP}/tui"
add_to_allowlist "${GROUP}/core" "${GROUP}/relay"
add_to_allowlist "${GROUP}/core" "${GROUP}/e2e"
add_to_allowlist "${GROUP}/core" "${GROUP}/linux-gtk"
add_to_allowlist "${GROUP}/core" "${GROUP}/ohttp-relay"
echo ""

# ── Show final state ────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
    echo "── Updated allowlists ──"
    show_allowlist "${GROUP}/core"
    show_allowlist "${GROUP}/vauchi-platform-swift"
    show_allowlist "${GROUP}/android"
    show_allowlist "${GROUP}/ios"
    show_allowlist "${GROUP}/macos"
    echo ""
fi

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Verify: push a change to core main and confirm downstream"
echo "     triggered pipelines can read core's supply-chain/config.toml"
echo "  2. Check that stale per-project trigger tokens are removed"
echo "     from CI/CD settings (all triggers now use CI_JOB_TOKEN)"
