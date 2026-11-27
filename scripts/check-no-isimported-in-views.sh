#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-isimported-in-views.sh — Forbid view-layer reads of
# `MobileContact.is_imported` / `.isImported`.
#
# Usage: check-no-isimported-in-views.sh <workspace_root>
# Example: check-no-isimported-in-views.sh /Users/me/Workspace/vauchi
#
# Background: core's `ContactDetailEngine` already encodes the rule
# "imported contacts get a delete_contact (Destructive) action;
# exchanged contacts get an archive_contact (Secondary) action" by
# emitting one or the other ScreenAction based on `is_imported`
# (`core/vauchi-app/src/ui/contact_detail.rs:505-521`). vauchi-platform
# 0.24.0 exposes the choice as
# `VauchiPlatform::contact_detail_footer_action_id(contact_id)`. View
# code that re-derives the choice locally by branching on
# `contact.isImported` duplicates the rule in a different language —
# §1A of the frontend pure-renderer audit
# (`_private/docs/problems/2026-04-25-isimported-frontend-cleanup/`).
#
# Scope: this script fences off only the *view* layer
# (`ios/Vauchi/Views/` + `android/app/src/main/kotlin/app/vauchi/ui/`).
# The model, repository, and view-model layers may legitimately read
# the field — the rule is "the view layer never branches on it".
#
# Pattern: `\.isImported\b` (member access) — the regex deliberately
# excludes initializer labels (`isImported: false` in struct/data-class
# constructors and `#Preview` / test fixtures), since those are writes,
# not reads.

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
ANDROID_UI="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/ui"

# Layout resolution: multi-repo workspace root (ios/ + android/ subdirs)
# or single-repo checkout root (Vauchi/ or app/ directly). Missing trees
# are skipped by the scanners below.
[ -d "$IOS_VIEWS" ] || IOS_VIEWS="$WORKSPACE_ROOT/Vauchi/Views"
[ -d "$ANDROID_UI" ] || ANDROID_UI="$WORKSPACE_ROOT/app/src/main/kotlin/app/vauchi/ui"

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
elif [ -f "$WORKSPACE_ROOT/settings.gradle.kts" ]; then
    if rg --quiet '^[[:space:]]*rootProject[.]name[[:space:]]*=[[:space:]]*"android-display"[[:space:]]*(//.*)?$' "$WORKSPACE_ROOT/settings.gradle.kts"; then
        independent_module="$WORKSPACE_ROOT"
    else
        settings_status=$?
        if [ "$settings_status" -ne 1 ]; then
            echo "ERROR: cannot inspect standalone display settings: $WORKSPACE_ROOT" >&2
            exit 2
        fi
    fi
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

scan_dir() {
    local dir="$1"
    local pattern='\.isImported\b'
    if [ ! -d "$dir" ]; then
        return 0
    fi
    # ripgrep: --line-number, --no-heading, regex, no binary, fixed alternation.
    # rg's default smart-case is fine — `isImported` is mixed-case anyway.
    local matches search_status
    if matches="$(rg --hidden --no-ignore --line-number --no-heading "$pattern" "$dir")"; then
        :
    else
        search_status=$?
        # Exit 1 means no matches; every other failure leaves the scan incomplete.
        if [ "$search_status" -ne 1 ]; then
            echo "ERROR: ripgrep could not complete the view scan: $dir" >&2
            return "$search_status"
        fi
    fi
    if [ -n "$matches" ]; then
        REPORT="$REPORT
$matches"
        VIOLATIONS=$((VIOLATIONS + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
}

scan_dir "$IOS_VIEWS"
scan_dir "$ANDROID_UI"
scan_dir "$ANDROID_DISPLAY_UI"
scan_dir "$ANDROID_INDEPENDENT_DISPLAY_UI"

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "FAIL: view-layer .isImported reads (§1A pure-renderer rule):"
    echo "$REPORT"
    echo
    echo "Use VauchiPlatform.contactDetailFooterActionId(contactId:) instead."
    echo "See _private/docs/problems/2026-04-25-isimported-frontend-cleanup/."
    exit 1
fi

echo "OK: no view-layer .isImported reads found"
exit 0
