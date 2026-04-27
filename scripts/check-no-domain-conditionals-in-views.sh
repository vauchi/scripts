#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-domain-conditionals-in-views.sh — Forbid view-layer reads of
# domain conditionals that should be decided in core (G5 lint guard).
#
# Usage: check-no-domain-conditionals-in-views.sh <workspace_root>
# Example: check-no-domain-conditionals-in-views.sh /Users/me/Workspace/vauchi
#
# Background: G1–G4 of the ScreenModel API gap workstream lifted four
# classes of business decision out of the iOS and Android view layers
# into core, where they belong (ADR-021/043 Humble UI):
#
#   G1 — `Component::CardPreview.visible_fields`        (core!695)
#   G2 — `MobileVisibilityLabelDetail.label_contacts`   (core!696)
#   G3 — `VauchiPlatform::get_failed_delivery_records`  (core!694)
#   G4 — `MobileContactDetailViewState`                 (core!697)
#
# This guard prevents the predicates from creeping back into view code.
#
# Scope: the *view* layer only —
#   ios/Vauchi/Views/, ios/Vauchi/CoreUI/
#   android/app/src/main/kotlin/app/vauchi/ui/,
#     android/app/src/main/kotlin/app/vauchi/ui/coreui/
# Repositories, view-models, and tests may legitimately read these
# fields — the rule is "the view layer never branches on them".
#
# Patterns flagged (member-access reads / equality comparisons):
#   - `\.isVerified\b`                  (G4)
#   - `\.isRecoveryTrusted\b`           (G4)
#   - `\.isHidden\b`                    (G4)
#   - `\.reciprocity\s*[=!]=`           (G4)
#   - `\.trustLevel\s*[=!]=`            (G4)
#   - `\.isFailed\b`                    (G3)
#
# Initializer labels (`isVerified: false` in struct/data-class
# constructors and `#Preview` fixtures) are exempt — those are writes,
# not reads. The patterns deliberately use member-access shape only.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <workspace_root>" >&2
    exit 2
fi

WORKSPACE_ROOT="$1"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: $WORKSPACE_ROOT is not a directory" >&2
    exit 2
fi

IOS_VIEWS="$WORKSPACE_ROOT/ios/Vauchi/Views"
IOS_COREUI="$WORKSPACE_ROOT/ios/Vauchi/CoreUI"
ANDROID_UI="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/ui"

# Each entry: pattern|description
PATTERNS=(
    '\.isVerified\b|G4 .isVerified read — use MobileContactDetailBadge.verified ∈ viewState.badges'
    '\.isRecoveryTrusted\b|G4 .isRecoveryTrusted read — use viewState.actions / .badges'
    '\.isHidden\b|G4 .isHidden read — use MobileContactDetailAction.toggleHidden { currently_hidden }'
    '\.reciprocity\s*[=!]=|G4 .reciprocity comparison — use viewState.banners'
    '\.trustLevel\s*[=!]=|G4 .trustLevel comparison — use MobileContactDetailAction.verify ∈ actions'
    '\.isFailed\b|G3 .isFailed read — use VauchiPlatform.getFailedDeliveryRecords()'
)

VIOLATIONS=0
REPORT=""

scan_dir_for_pattern() {
    local dir="$1"
    local pattern="$2"
    local description="$3"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local matches
    matches="$(rg --line-number --no-heading "$pattern" "$dir" || true)"
    if [ -n "$matches" ]; then
        REPORT="$REPORT
${description}:
$matches
"
        VIOLATIONS=$((VIOLATIONS + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
}

for entry in "${PATTERNS[@]}"; do
    pattern="${entry%%|*}"
    description="${entry#*|}"
    scan_dir_for_pattern "$IOS_VIEWS" "$pattern" "$description"
    scan_dir_for_pattern "$IOS_COREUI" "$pattern" "$description"
    scan_dir_for_pattern "$ANDROID_UI" "$pattern" "$description"
done

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "FAIL: view-layer domain conditionals (G5 / ADR-021/043 Humble UI):"
    echo "$REPORT"
    echo
    echo "View code must not branch on raw MobileContact / MobileDeliveryRecord"
    echo "fields. Use the typed view-state APIs from core (G1–G4):"
    echo "  - VauchiPlatform.contactDetailViewState(contactId)  (G4)"
    echo "  - VauchiPlatform.getFailedDeliveryRecords()          (G3)"
    echo "  - Component::CardPreview.visible_fields             (G1)"
    echo "  - MobileVisibilityLabelDetail.label_contacts         (G2)"
    echo
    echo "See _private/docs/problems/2026-04-27-screenmodel-api-gaps-symmetric-frontend-violations/."
    exit 1
fi

echo "OK: no view-layer domain-conditional reads found"
exit 0
