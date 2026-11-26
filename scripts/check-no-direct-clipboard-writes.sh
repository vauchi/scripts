#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-direct-clipboard-writes.sh — Forbid view-layer direct
# writes to the system clipboard.
#
# Usage: check-no-direct-clipboard-writes.sh <workspace_root>
# Example: check-no-direct-clipboard-writes.sh /Users/me/Workspace/vauchi
#
# Background: sensitive payloads (recovery claims, vouchers, proofs,
# credentials) that hit the clipboard must go through a frontend-
# level helper that applies platform-specific guards (auto-clear
# TTL, EXTRA_IS_SENSITIVE flag, localOnly + expirationDate). Direct
# writes from view code skip those guards and were the exact gap
# that the 2026-05-01 audit (criterion 3) caught in iOS RecoveryView.
#
# Cross-platform reference + threat model:
# `_private/docs/reference/2026-05-02-clipboard-protection.md`.
#
# Scope: this script fences off only the *view* layer
# (`ios/Vauchi/Views/`, `ios/Vauchi/CoreUI/`,
# `android/app/src/main/kotlin/app/vauchi/ui/`).
# The helper modules themselves and the model / repository / view-
# model layers are excluded — those are the only callers allowed to
# touch the platform pasteboard API.
#
# Patterns:
#   iOS:     `UIPasteboard\.general\b` — any access to the shared
#            pasteboard from view code is suspect; the helper lives
#            in `ios/Vauchi/Services/ContactActions.swift` and is
#            the only allowed call site.
#   Android: `\.setPrimaryClip\b` — the only platform write API the
#            helper uses; the helper lives in
#            `android/app/src/main/kotlin/app/vauchi/util/ClipboardUtils.kt`.
#
# Reads (`primaryClip` getter, `NSPasteboard.string(forType:)`) are
# fine — there's nothing to leak in that direction.

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

VIOLATIONS=0
REPORT=""

scan() {
    local dir="$1"
    local pattern="$2"
    local label="$3"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local matches search_status
    if matches="$(rg --line-number --no-heading "$pattern" "$dir")"; then
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
[$label]
$matches"
        VIOLATIONS=$((VIOLATIONS + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
}

scan "$IOS_VIEWS"   'UIPasteboard\.general\b' "iOS Views"
scan "$IOS_COREUI"  'UIPasteboard\.general\b' "iOS CoreUI"
scan "$ANDROID_UI"  '\.setPrimaryClip\b'      "Android UI"
scan "$ANDROID_DISPLAY_UI" '\.setPrimaryClip\b' "Android display"

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "FAIL: view-layer direct clipboard writes (clipboard protection rule):"
    echo "$REPORT"
    echo
    echo "View code must route through the platform helper:"
    echo "  iOS:     ContactActions.copyToClipboard(_:)"
    echo "             ios/Vauchi/Services/ContactActions.swift"
    echo "  Android: ClipboardUtils.copyWithAutoClear(...) or ClipboardUtils.copy(...)"
    echo "             android/app/src/main/kotlin/app/vauchi/util/ClipboardUtils.kt"
    echo
    echo "See _private/docs/reference/2026-05-02-clipboard-protection.md"
    exit 1
fi

echo "OK: no view-layer direct clipboard writes found"
exit 0
