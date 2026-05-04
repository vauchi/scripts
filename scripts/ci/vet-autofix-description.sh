#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck disable=SC2016
# Reason: single-quoted printf format strings are intentional —
# every backtick + `${var}` lookalike is *literal markdown*, not
# shell expansion. Same precedent as
# scripts/tests/escape-mr-mentions.test.sh.

# vet-autofix-description.sh — Build the MR description block that
# warns reviewers when a cargo-vet auto-sync MR also bumps
# `vauchi-core` to a rev that touched UI code. Origin:
# `_private/docs/problems/2026-05-03-vet-autosync-stale-snapshots`
# Phase 1 (G2).
#
# Usage:
#   echo "core/vauchi-app/src/ui/settings.rs" \
#     | vet-autofix-description.sh OLD_REV NEW_REV
#
# Args:
#   OLD_REV  — vauchi-core git SHA from Cargo.lock before the bump
#   NEW_REV  — vauchi-core git SHA from Cargo.lock after the bump
#
# Stdin: list of file paths the caller has detected as changed
# between OLD_REV and NEW_REV. The caller is responsible for
# filtering to UI-relevant paths (typically `core/vauchi-app/src/ui/`)
# — this helper just formats whatever list it receives.
#
# Output: a markdown block to append to the auto-sync MR
# description, OR empty if no useful warning can be produced
# (missing revs, same rev, or empty file list).

set -euo pipefail

OLD_REV="${1:-}"
NEW_REV="${2:-}"

# No revs, or unchanged rev — nothing to warn about.
if [[ -z "$OLD_REV" || -z "$NEW_REV" || "$OLD_REV" == "$NEW_REV" ]]; then
    exit 0
fi

# Read the file list. If empty, no warning — the bump didn't touch
# UI code so reviewers don't need a snapshot-regen heads-up.
files=$(cat)
if [[ -z "$files" ]]; then
    exit 0
fi

# Short-form revs (8 chars) for readability when the input is a
# full SHA. Pass through anything shorter unchanged.
short_rev() {
    local rev="$1"
    if [[ ${#rev} -ge 8 ]]; then
        printf '%s' "${rev:0:8}"
    else
        printf '%s' "$rev"
    fi
}

old_short=$(short_rev "$OLD_REV")
new_short=$(short_rev "$NEW_REV")

# Render the block. The leading blank line + horizontal rule lets
# this slot in at the bottom of the existing MR description without
# ambiguous markdown nesting.
printf '\n'
printf -- '---\n'
printf '\n'
printf '⚠ **Lockfile also bumps `vauchi-core`: `%s` → `%s`**\n' "$old_short" "$new_short"
printf '\n'
printf 'UI files touched between revs (`core/vauchi-app/src/ui/`):\n'
printf '\n'
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    printf -- '- `%s`\n' "$path"
done <<<"$files"
printf '\n'
printf 'Snapshot regen may be required if any of the above changed\n'
printf '`ScreenModel` shape. Run the repo'\''s snapshot-record command\n'
printf '(e.g. `cargo insta test --accept`) before merging if CI flags\n'
printf 'snapshot drift.\n'
