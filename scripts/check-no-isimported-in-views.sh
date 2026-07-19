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
    local matches
    matches="$(rg --line-number --no-heading "$pattern" "$dir" || true)"
    if [ -n "$matches" ]; then
        REPORT="$REPORT
$matches"
        VIOLATIONS=$((VIOLATIONS + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
}

scan_dir "$IOS_VIEWS"
scan_dir "$ANDROID_UI"

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
