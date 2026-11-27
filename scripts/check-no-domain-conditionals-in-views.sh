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

# VAUCHI_ANDROID_DISPLAY_ROOT declares an additional required library checkout.
set -euo pipefail

# Guard fails LOUD without ripgrep: `rg … || true` silently reported
# clean wherever rg was missing (both CI runner flavors) — a guard
# that self-disables is worse than none.
if ! command -v rg >/dev/null 2>&1; then
    echo "ERROR: ripgrep (rg) is required by $(basename "$0") — install it (apt/brew/apk add ripgrep)" >&2
    exit 2
fi

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

# Layout resolution: multi-repo workspace root (ios/ + android/ subdirs)
# or single-repo checkout root (Vauchi/ or app/ directly). Missing trees
# are skipped by the scanners below.
[ -d "$IOS_VIEWS" ] || IOS_VIEWS="$WORKSPACE_ROOT/Vauchi/Views"
[ -d "$IOS_COREUI" ] || IOS_COREUI="$WORKSPACE_ROOT/Vauchi/CoreUI"
[ -d "$ANDROID_UI" ] || ANDROID_UI="$WORKSPACE_ROOT/app/src/main/kotlin/app/vauchi/ui"

# Each entry: pattern|description
PATTERNS=(
    '\.isVerified\b|G4 .isVerified read — use MobileContactDetailBadge.verified ∈ viewState.badges'
    '\.isRecoveryTrusted\b|G4 .isRecoveryTrusted read — use viewState.actions / .badges'
    '\.isHidden\b|G4 .isHidden read — use MobileContactDetailAction.toggleHidden { currently_hidden }'
    '\.reciprocity\s*[=!]=|G4 .reciprocity comparison — use viewState.banners'
    '\.trustLevel\s*[=!]=|G4 .trustLevel comparison — use MobileContactDetailAction.verify ∈ actions'
    '\.isFailed\b|G3 .isFailed read — use VauchiPlatform.getFailedDeliveryRecords()'
)

ANDROID_DISPLAY_UI="$WORKSPACE_ROOT/android/display/src/main/kotlin/app/vauchi/ui"
[ -d "$ANDROID_DISPLAY_UI" ] || ANDROID_DISPLAY_UI="$WORKSPACE_ROOT/display/src/main/kotlin/app/vauchi/ui"
ANDROID_SETTINGS="$WORKSPACE_ROOT/android/settings.gradle.kts"
[ -f "$ANDROID_SETTINGS" ] || ANDROID_SETTINGS="$WORKSPACE_ROOT/settings.gradle.kts"
if [ -f "$ANDROID_SETTINGS" ]; then
    display_settings=$(sed 's,//.*$,,' "$ANDROID_SETTINGS")
    if [[ "$display_settings" == *'":display"'* ]]; then
        if ! display_inventory=$(rg --files --glob '*.kt' --glob '*.java' "$ANDROID_DISPLAY_UI") || [ -z "$display_inventory" ]; then
            echo "ERROR: declared display module has no readable view sources: $ANDROID_DISPLAY_UI" >&2
            exit 2
        fi
    fi
fi

ANDROID_INDEPENDENT_DISPLAY_UI=""
independent_module=""
if [ "${VAUCHI_ANDROID_DISPLAY_ROOT+x}" = x ]; then
    independent_module="$VAUCHI_ANDROID_DISPLAY_ROOT"
elif [ -e "$WORKSPACE_ROOT/android-display" ] || [ -L "$WORKSPACE_ROOT/android-display" ]; then
    independent_module="$WORKSPACE_ROOT/android-display"
elif [ -d "$WORKSPACE_ROOT/src" ]; then
    independent_module="$WORKSPACE_ROOT"
fi
if [ -n "$independent_module" ] || [ "${VAUCHI_ANDROID_DISPLAY_ROOT+x}" = x ]; then
    ANDROID_INDEPENDENT_DISPLAY_UI="$independent_module/src/main/kotlin/app/vauchi/ui"
    if [ -z "$independent_module" ] || [ -L "$independent_module" ] || [ -L "$independent_module/src" ] || [ ! -d "$independent_module/src" ]; then
        echo "ERROR: independent display module has no regular source root: $independent_module" >&2
        exit 2
    fi
    if ! linked_sources=$(find "$independent_module/src" -type l) || [ -n "$linked_sources" ]; then
        echo "ERROR: independent display source tree contains links or cannot be inspected: $independent_module" >&2
        exit 2
    fi
    if ! display_inventory=$(rg --files --hidden --no-ignore --glob '*.kt' --glob '*.java' "$ANDROID_INDEPENDENT_DISPLAY_UI") || [ -z "$display_inventory" ]; then
        echo "ERROR: independent display module has no readable view sources: $ANDROID_INDEPENDENT_DISPLAY_UI" >&2
        exit 2
    fi
fi

VIOLATIONS=0
REPORT=""

scan_dir_for_pattern() {
    local dir="$1"
    local pattern="$2"
    local description="$3"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local matches search_status
    if matches="$(rg --hidden --no-ignore --line-number --no-heading "$pattern" "$dir")"; then
        :
    else
        search_status=$?
        if [ "$search_status" -ne 1 ]; then
            echo "ERROR: ripgrep could not complete the view scan: $dir" >&2
            return "$search_status"
        fi
    fi
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
    scan_dir_for_pattern "$ANDROID_DISPLAY_UI" "$pattern" "$description"
    scan_dir_for_pattern "$ANDROID_INDEPENDENT_DISPLAY_UI" "$pattern" "$description"
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
