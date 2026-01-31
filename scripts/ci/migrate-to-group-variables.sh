#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Migrate Per-Project CI Variables to Group Level
#
# Moves trigger tokens and shared CI variables from individual project
# settings to the vauchi group level, so all repos inherit them.
#
# Prerequisites:
#   - glab CLI authenticated (glab auth status)
#   - Owner access to the vauchi group (for creating group variables)
#
# What this does:
#   1. Lists current per-project CI variables
#   2. Lists current group-level CI variables
#   3. Copies specified project variables to group level
#   4. Optionally removes the per-project copies
#
# Variables to migrate:
#   ANDROID_APP_TRIGGER_TOKEN  (vauchi-mobile-android → vauchi group)
#   IOS_APP_TRIGGER_TOKEN      (vauchi-mobile-swift → vauchi group)
#
# Usage:
#   ./migrate-to-group-variables.sh [--dry-run]

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

echo "=== Group-Level CI Variable Migration ==="
echo ""

# ── Step 1: Show current state ───────────────────────────────
echo "── Current per-project variables ──"
echo ""
echo "  vauchi-mobile-android:"
glab variable list -R "${GROUP}/vauchi-mobile-android" 2>/dev/null | sed 's/^/    /' || echo "    (none or no access)"
echo ""
echo "  vauchi-mobile-swift:"
glab variable list -R "${GROUP}/vauchi-mobile-swift" 2>/dev/null | sed 's/^/    /' || echo "    (none or no access)"
echo ""

echo "── Current group variables ──"
glab variable list -g "${GROUP}" 2>/dev/null | sed 's/^/    /' || echo "    (none or no access)"
echo ""

# ── Step 2: Migrate variables ────────────────────────────────
echo "── Migration ──"
echo ""
echo "Variables to migrate to group level:"
echo "  ANDROID_APP_TRIGGER_TOKEN  (from vauchi-mobile-android)"
echo "  IOS_APP_TRIGGER_TOKEN      (from vauchi-mobile-swift)"
echo ""

# Try to read the project-level values (may fail if masked)
migrate_var() {
    local var_name="$1"
    local source_repo="$2"

    echo "── ${var_name} (from ${source_repo}) ──"

    # Try to get the value from the project
    local value
    value=$(glab variable get "${var_name}" -R "${GROUP}/${source_repo}" 2>/dev/null | tail -1) || true

    if [[ -n "$value" && "$value" != *"error"* && "$value" != *"***"* ]]; then
        echo "  Found value in project (${#value} chars)"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY RUN] Would create group variable ${var_name}"
            return
        fi

        # Create at group level
        echo "$value" | glab variable set "${var_name}" -g "${GROUP}" --masked --protected 2>&1 && \
            echo "  ✓ Created at group level" || \
            echo "  ✗ Failed (may already exist — use 'glab variable update' to overwrite)"
    else
        echo "  Could not read value from project (masked or no access)"
        echo "  Enter value manually, or copy from:"
        echo "    GitLab > ${GROUP}/${source_repo} > Settings > CI/CD > Variables"
        echo ""

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY RUN] Would prompt for value"
            return
        fi

        read -rsp "  Enter ${var_name} value (or press Enter to skip): " manual_value
        echo ""

        if [[ -n "$manual_value" ]]; then
            echo "$manual_value" | glab variable set "${var_name}" -g "${GROUP}" --masked --protected 2>&1 && \
                echo "  ✓ Created at group level" || \
                echo "  ✗ Failed (may already exist)"
        else
            echo "  Skipped"
        fi
    fi
    echo ""
}

migrate_var "ANDROID_APP_TRIGGER_TOKEN" "vauchi-mobile-android"
migrate_var "IOS_APP_TRIGGER_TOKEN" "vauchi-mobile-swift"

# ── Step 3: Verify ───────────────────────────────────────────
echo "── Verification ──"
echo "  Group variables after migration:"
glab variable list -g "${GROUP}" 2>/dev/null | sed 's/^/    /' || echo "    (could not list)"
echo ""

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Verify downstream triggers work (push a tag to core)"
echo "  2. Remove per-project variables:"
echo "     glab variable delete ANDROID_APP_TRIGGER_TOKEN -R ${GROUP}/vauchi-mobile-android"
echo "     glab variable delete IOS_APP_TRIGGER_TOKEN -R ${GROUP}/vauchi-mobile-swift"
echo "  3. If using CI_JOB_TOKEN allowlist (setup-job-token-allowlist.sh),"
echo "     trigger tokens can eventually be removed entirely"
