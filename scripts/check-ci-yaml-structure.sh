#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Structural sanity check for a .gitlab-ci.yml, for use when GitLab's own
# lint endpoint cannot be reached.
#
# Why this exists: the pre-push hook validates CI config with
# `glab ci lint`, which POSTs to the project's lint endpoint. A token
# without permission there gets 403, and the hook reported that as
# "CI config is invalid" — an authorization failure dressed up as a
# validation failure. Pushes to any repo using `project:` includes then
# fail for a reason unrelated to the config.
#
# This catches the defect class that removing lines most often causes:
# a mapping key left with nothing under it. Deleting a job's only
# variable leaves `variables:` pointing at null, which GitLab rejects.
# Observed for real: dropping VAUCHI_LOCALES_DIR from tui emptied
# `variables:` in four jobs.
#
# It is deliberately NOT a YAML parser or a substitute for server lint —
# it cannot resolve `include:` or validate keywords. It is the cheap
# structural floor that survives having no network and no token.
#
# Usage:
#   check-ci-yaml-structure.sh <path/to/.gitlab-ci.yml>
#
# Exit: 0 clean, 1 structural problem found, 2 usage/IO error.
#
# Portability: POSIX shell + awk only (BusyBox/BSD/GNU safe).
set -eu

FILE="${1:-}"
if [ -z "$FILE" ]; then
    printf 'check-ci-yaml-structure: usage: %s <.gitlab-ci.yml>\n' "$0" >&2
    exit 2
fi
if [ ! -f "$FILE" ]; then
    printf 'check-ci-yaml-structure: no such file: %s\n' "$FILE" >&2
    exit 2
fi

# A mapping key whose block body is empty. `script:` and friends take a
# list; `variables:` takes a map. Either way, nothing beneath the key
# means null, which GitLab rejects.
#
# A key is empty when the next line that carries content is indented no
# deeper than the key itself. Blank lines and comments are skipped, since
# both may legitimately sit inside a block.
findings=$(awk '
    # Track the pending key across lines.
    pending_key != "" {
        line = $0
        # Skip blanks and comment-only lines.
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*#/) next

        # Measure this line indent.
        indent = match(line, /[^ ]/) - 1
        if (indent <= pending_indent) {
            printf "%s:%d: `%s:` has an empty body\n", FILENAME, pending_line, pending_key
        }
        pending_key = ""
    }

    /^[[:space:]]*(script|before_script|after_script|variables|rules|artifacts|needs):[[:space:]]*$/ {
        pending_indent = match($0, /[^ ]/) - 1
        pending_key = $0
        sub(/^[[:space:]]*/, "", pending_key)
        sub(/:[[:space:]]*$/, "", pending_key)
        pending_line = FNR
    }

    END {
        # A key at end-of-file with nothing after it is empty too.
        if (pending_key != "") {
            printf "%s:%d: `%s:` has an empty body\n", FILENAME, pending_line, pending_key
        }
    }
' "$FILE")

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" >&2
    printf '\n' >&2
    printf 'A mapping key with nothing under it is null, and GitLab rejects it.\n' >&2
    printf 'This usually follows a deletion that removed a block body but left\n' >&2
    printf 'its key behind — drop the key too.\n' >&2
    exit 1
fi

printf 'check-ci-yaml-structure: %s OK\n' "$FILE"
