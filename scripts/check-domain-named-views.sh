#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-domain-named-views.sh — Forbid new domain-named SwiftUI view
# files at the top of `Vauchi/Views/` outside an explicit allow-list.
#
# Usage: check-domain-named-views.sh <repo_root>
# Example: check-domain-named-views.sh /Users/me/Workspace/vauchi/ios
#
# Background: per ADR-021/043 (Humble UI), every screen renders a
# core `ScreenModel` via `CoreScreenView`. Each named view file
# (e.g. `SettingsView.swift`, `ContactsView.swift`) duplicates layout
# for a specific screen and forces parallel maintenance whenever core
# changes the model. The destination is zero domain-named views — only
# the platform-required ones (camera host, lock screen, etc.) remain.
#
# Ratchet-down model: the allow-list at
# `<repo_root>/.domain-named-views-allowlist` captures the current set
# of named views. Each retirement MR shrinks the list. New filenames
# not on the list cause the lint to fail. The script also warns if an
# allow-listed file no longer exists, prompting list pruning.
#
# Scope: only top-level `*.swift` files directly under `Vauchi/Views/`.
# Subdirectories (`Components/`, `Onboarding/`, …) are platform-owned
# reusable widgets and are out of scope.
#
# Source records:
#   _private/docs/problems/2026-05-02-ios-humble-ui-deep-retirement/   (G5)
#   _private/docs/problems/2026-05-02-macos-humble-ui-retirement/      (G6)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo_root>" >&2
    exit 2
fi

REPO_ROOT="$1"

if [ ! -d "$REPO_ROOT" ]; then
    echo "Error: $REPO_ROOT is not a directory" >&2
    exit 2
fi

VIEWS_DIR="$REPO_ROOT/Vauchi/Views"
ALLOWLIST_FILE="$REPO_ROOT/.domain-named-views-allowlist"

if [ ! -d "$VIEWS_DIR" ]; then
    # Repo has no Vauchi/Views/ — nothing to check.
    exit 0
fi

if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "Error: missing allow-list at $ALLOWLIST_FILE" >&2
    echo "Create one listing the currently-permitted view filenames." >&2
    exit 2
fi

# Build allow-set (skip blank lines and `#` comments).
ALLOWED="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST_FILE" | sed 's/[[:space:]]*$//' | sort -u)"

# Enumerate present top-level *.swift files (filenames only, sorted).
PRESENT="$(find "$VIEWS_DIR" -maxdepth 1 -type f -name '*.swift' -exec basename {} \; | sort -u)"

# New violations = present \ allowed.
NEW_VIOLATIONS="$(comm -23 <(echo "$PRESENT") <(echo "$ALLOWED"))"

# Stale entries = allowed \ present.
STALE_ENTRIES="$(comm -13 <(echo "$PRESENT") <(echo "$ALLOWED"))"

EXIT=0

if [ -n "$NEW_VIOLATIONS" ]; then
    echo "FAIL: new domain-named view files in $VIEWS_DIR (Humble UI rule, ADR-021/043):"
    echo "$NEW_VIOLATIONS" | awk '{print "  " $0}'
    echo
    echo "Render the corresponding core ScreenModel via CoreScreenView instead."
    echo "If the view is platform-required (camera host, lock screen, etc.),"
    echo "add it to $ALLOWLIST_FILE with a comment explaining why."
    EXIT=1
fi

if [ -n "$STALE_ENTRIES" ]; then
    echo "WARN: allow-list entries no longer present in $VIEWS_DIR:"
    echo "$STALE_ENTRIES" | awk '{print "  " $0}'
    echo "Remove them from $ALLOWLIST_FILE (ratchet-down)."
    EXIT=1
fi

if [ "$EXIT" -eq 0 ]; then
    echo "OK: domain-named-views allow-list matches present files ($(echo "$PRESENT" | wc -l | tr -d ' ') entries)"
fi

exit "$EXIT"
